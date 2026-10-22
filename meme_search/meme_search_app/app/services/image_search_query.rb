# frozen_string_literal: true

class ImageSearchQuery
  DEFAULT_RESULT_LIMIT = 10
  MAX_RESULT_LIMIT = 20
  STOPWORDS = %w[
    a i me my myself we our ours ourselves you your yours yourself yourselves
    he him his himself she her hers herself it its itself they them their theirs
    themselves what which who whom this that these those am is are was were be
    been being have has had having do does did doing an the and but if or as
    until while of at by for with above below to from up down in out on off over
    under how all any both each few more most other some such no nor not only own
    same so than too very s
  ].freeze

  # selected_tag_names and selected_path_names (exact ImagePath names) each match
  # any of their entries; when both are given a meme has to satisfy both.
  def initialize(query:, mode:, selected_tag_names: [], selected_path_names: [], limit: DEFAULT_RESULT_LIMIT)
    @query = query.to_s
    @mode = mode.to_s
    @selected_tag_names = Array(selected_tag_names).compact_blank
    @selected_path_names = Array(selected_path_names).compact_blank
    @limit = normalize_limit(limit)
  end

  def call
    case mode
    when "0", "keyword"
      keyword_results
    when "1", "vector"
      vector_results
    else
      []
    end
  end

  private

    attr_reader :query, :mode, :selected_tag_names, :selected_path_names, :limit

    def keyword_results
      relation = ImageCore.search_any_word(remove_stopwords(query))
      relation = relation.where(id: eligible_image_core_ids) if filtered?
      relation.limit(limit).to_a
    end

    def vector_results
      image_core = ImageCore.first
      return [] unless image_core

      query_embedding = ImageEmbedding.new(image_core_id: image_core.id, snippet: query)
      query_embedding.compute_embedding
      # The filter works before ranking only because this is an exact scan: no vector
      # index exists. An approximate index (HNSW) would filter after its candidate
      # search and needs pgvector's iterative index scan to keep filtered results.
      ranked_ids = query_embedding.get_neighbor_image_core_ids(
        limit: limit,
        image_core_ids: filtered? ? eligible_image_core_ids : nil
      )
      image_cores_by_id = ImageCore.where(id: ranked_ids).index_by(&:id)

      ranked_ids.filter_map { |image_core_id| image_cores_by_id[image_core_id] }
    end

    def filtered?
      selected_tag_names.any? || selected_path_names.any?
    end

    def eligible_image_core_ids
      relation = ImageCore.all
      relation = relation.where(id: tagged_image_core_ids) if selected_tag_names.any?
      relation = relation.where(image_path_id: ImagePath.where(name: selected_path_names).select(:id)) if selected_path_names.any?
      relation.select(:id)
    end

    def tagged_image_core_ids
      ImageCore
        .joins(image_tags: :tag_name)
        .where(tag_names: { name: selected_tag_names })
        .select(:id)
    end

    def remove_stopwords(input)
      input.split.reject { |word| STOPWORDS.include?(word.downcase) }.join(" ")
    end

    def normalize_limit(value)
      value.to_i.clamp(1, MAX_RESULT_LIMIT)
    end
end
