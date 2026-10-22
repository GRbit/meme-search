# frozen_string_literal: true

# Ranks other memes by cosine distance to one meme's description embedding.
#
# The source is represented by a single vector, its full-text chunk (the longest snippet: chunk_text
# stores the whole description first and only adds shorter windows). Comparing every source chunk
# with every stored chunk would multiply the cost of an unindexed scan by the chunk count (about
# words/2 + 1) and let a shared two-word window outrank memes about the same thing. Candidates keep
# their best chunk, like vector search.
class SimilarMemesQuery
  def initialize(image_core:, limit: ImageSearchQuery::DEFAULT_RESULT_LIMIT)
    @image_core = image_core
    @limit = limit.to_i.clamp(1, ImageSearchQuery::MAX_RESULT_LIMIT)
  end

  def call
    ranked_ids = neighbor_image_core_ids
    image_cores_by_id = ImageCore.where(id: ranked_ids).index_by(&:id)

    ranked_ids.filter_map { |image_core_id| image_cores_by_id[image_core_id] }
  end

  private

    attr_reader :image_core, :limit

    def neighbor_image_core_ids
      ImageEmbedding
        .from("image_embeddings candidate")
        .joins("CROSS JOIN (#{source_embedding.to_sql}) source")
        .where("candidate.embedding IS NOT NULL")
        .where.not(candidate: { image_core_id: image_core.id })
        .group("candidate.image_core_id")
        .order(
          Arel.sql("MIN(candidate.embedding <=> source.embedding) ASC"),
          Arel.sql("candidate.image_core_id ASC")
        )
        .limit(limit)
        .pluck(Arel.sql("candidate.image_core_id"))
    end

    # Subquery rather than a fetched vector keeps the lookup one statement and the 384 floats in the database.
    def source_embedding
      ImageEmbedding
        .where(image_core_id: image_core.id)
        .where.not(embedding: nil)
        .order(Arel.sql("LENGTH(snippet) DESC"), :id)
        .limit(1)
        .select(:embedding)
    end
end
