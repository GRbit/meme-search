# frozen_string_literal: true

class ImageSearchQuery
  DEFAULT_RESULT_LIMIT = 10
  MAX_RESULT_LIMIT = 20
  Page = Struct.new(:results, :more)
  STOPWORDS = %w[
    a i me my myself we our ours ourselves you your yours yourself yourselves
    he him his himself she her hers herself it its itself they them their theirs
    themselves what which who whom this that these those am is are was were be
    been being have has had having do does did doing an the and but if or as
    until while of at by for with above below to from up down in out on off over
    under how all any both each few more most other some such no nor not only own
    same so than too very s
  ].freeze

  def initialize(query:, mode:, selected_tag_names: [], limit: DEFAULT_RESULT_LIMIT, offset: 0)
    @query = query.to_s
    @mode = mode.to_s
    @selected_tag_names = Array(selected_tag_names).compact_blank
    @limit = normalize_limit(limit)
    @offset = [ offset.to_i, 0 ].max
  end

  def call
    fetch(limit)
  end

  # Fetches one row past the limit so callers learn whether another page exists
  # without a second count query (vector mode has no cheap total).
  def page
    rows = fetch(limit + 1)
    Page.new(rows.first(limit), rows.length > limit)
  end

  private

    attr_reader :query, :mode, :selected_tag_names, :limit, :offset

    def fetch(count)
      case mode
      when "0", "keyword"
        keyword_results(count)
      when "1", "vector"
        vector_results(count)
      else
        []
      end
    end

    def keyword_results(count)
      relation = ImageCore.search_any_word(remove_stopwords(query))
      relation = relation.where(id: tagged_image_core_ids) if selected_tag_names.any?
      # pg_search appends the primary key to its rank order, so ties are stable across pages
      relation.limit(count).offset(offset).to_a
    end

    def vector_results(count)
      image_core = ImageCore.first
      return [] unless image_core

      query_embedding = ImageEmbedding.new(image_core_id: image_core.id, snippet: query)
      query_embedding.compute_embedding
      ranked_ids = query_embedding.get_neighbor_image_core_ids(
        limit: count,
        offset: offset,
        image_core_ids: selected_tag_names.any? ? tagged_image_core_ids : nil
      )
      image_cores_by_id = ImageCore.where(id: ranked_ids).index_by(&:id)

      ranked_ids.filter_map { |image_core_id| image_cores_by_id[image_core_id] }
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
