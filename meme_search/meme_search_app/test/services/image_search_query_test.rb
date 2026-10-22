require "test_helper"

class ImageSearchQueryTest < ActiveSupport::TestCase
  test "performs keyword search with the existing result limit" do
    results = ImageSearchQuery.new(query: "bunny", mode: "keyword").call

    assert_equal [ image_cores(:three) ], results
    assert_operator results.length, :<=, ImageSearchQuery::DEFAULT_RESULT_LIMIT
  end

  test "removes stopwords before keyword search" do
    results = ImageSearchQuery.new(query: "this bunny", mode: "0").call

    assert_equal [ image_cores(:three) ], results.to_a
  end

  test "filters keyword results by any selected tag" do
    results = ImageSearchQuery.new(
      query: "image",
      mode: "keyword",
      selected_tag_names: [ "tag_one" ]
    ).call

    expected_ids = [ image_cores(:one).id, image_cores(:two).id ].sort
    assert_equal expected_ids, results.map(&:id).sort
  end

  test "tag_match all keeps only memes that carry every selected tag" do
    results = ImageSearchQuery.new(
      query: "image",
      mode: "keyword",
      selected_tag_names: [ "tag_one", "tag_two" ],
      tag_match: "all"
    ).call

    assert_equal [ image_cores(:two).id ], results.map(&:id)
  end

  test "tag_match all ignores duplicate tag names and finds nothing for an unknown tag" do
    duplicated = ImageSearchQuery.new(
      query: "image",
      mode: "keyword",
      selected_tag_names: [ "tag_one", "tag_one" ],
      tag_match: "all"
    ).call
    unknown = ImageSearchQuery.new(
      query: "image",
      mode: "keyword",
      selected_tag_names: [ "tag_one", "no_such_tag" ],
      tag_match: "all"
    ).call

    assert_equal [ image_cores(:one).id, image_cores(:two).id ].sort, duplicated.map(&:id).sort
    assert_empty unknown
  end

  test "tag_match any is the default" do
    explicit = ImageSearchQuery.new(
      query: "image", mode: "keyword", selected_tag_names: [ "tag_one", "tag_two" ], tag_match: "any"
    ).call
    implicit = ImageSearchQuery.new(
      query: "image", mode: "keyword", selected_tag_names: [ "tag_one", "tag_two" ]
    ).call

    assert_equal explicit.map(&:id).sort, implicit.map(&:id).sort
    assert_equal 3, implicit.length
  end

  test "tag_match all restricts vector neighbor selection to memes with every tag" do
    query_embedding = Object.new
    captured = {}
    query_embedding.define_singleton_method(:compute_embedding) { Array.new(384, 0.5) }
    query_embedding.define_singleton_method(:get_neighbor_image_core_ids) do |limit:, image_core_ids:|
      captured[:eligible_ids] = image_core_ids.to_a.map(&:id)
      []
    end

    ImageEmbedding.stub(:new, query_embedding) do
      ImageSearchQuery.new(
        query: "reaction meme",
        mode: "vector",
        selected_tag_names: [ "tag_one", "tag_two" ],
        tag_match: "all"
      ).call
    end

    assert_equal [ image_cores(:two).id ], captured[:eligible_ids]
  end

  test "filters keyword results before applying the result limit" do
    matching_tag = tag_names(:two)
    untagged = image_cores(:one)
    tagged = image_cores(:three)
    tagged.image_tags.create!(tag_name: matching_tag) unless tagged.image_tags.exists?(tag_name: matching_tag)
    ranked_relation = ImageCore.where(id: [ untagged.id, tagged.id ]).order(:id)

    ImageCore.stub(:search_any_word, ranked_relation) do
      results = ImageSearchQuery.new(
        query: "image",
        mode: "keyword",
        selected_tag_names: [ matching_tag.name ],
        limit: 1
      ).call

      assert_equal [ tagged ], results
    end
  end

  test "performs vector search through the embedding boundary" do
    query_embedding = Minitest::Mock.new
    query_embedding.expect(:compute_embedding, Array.new(384, 0.5))
    query_embedding.expect(
      :get_neighbor_image_core_ids,
      [ image_cores(:three).id, image_cores(:one).id ],
      limit: 10,
      image_core_ids: nil,
      offset: 0
    )

    ImageEmbedding.stub(:new, query_embedding) do
      results = ImageSearchQuery.new(query: "reaction meme", mode: "vector").call

      assert_equal [ image_cores(:three), image_cores(:one) ], results
    end

    query_embedding.verify
  end

  test "passes the tag filter into vector neighbor selection before its limit" do
    query_embedding = Object.new
    captured = {}
    tagged_image_core_id = image_cores(:three).id
    query_embedding.define_singleton_method(:compute_embedding) { Array.new(384, 0.5) }
    query_embedding.define_singleton_method(:get_neighbor_image_core_ids) do |limit:, image_core_ids:, offset:|
      captured[:limit] = limit
      captured[:eligible_ids] = image_core_ids.to_a.map(&:id)
      [ tagged_image_core_id ]
    end

    ImageEmbedding.stub(:new, query_embedding) do
      results = ImageSearchQuery.new(
        query: "reaction meme",
        mode: "vector",
        selected_tag_names: [ "tag_two" ],
        limit: 1
      ).call

      assert_equal 1, captured[:limit]
      assert_includes captured[:eligible_ids], image_cores(:three).id
      assert_not_includes captured[:eligible_ids], image_cores(:one).id
      assert_equal [ image_cores(:three) ], results
    end
  end

  test "image embedding limits distinct memes after ranking duplicate embeddings" do
    first_image = image_cores(:one)
    second_image = image_cores(:two)
    query_vector = [ 1.0 ] + Array.new(383, 0.0)
    ImageEmbedding.create!(
      image_core: first_image,
      snippet: "exact duplicate one",
      embedding: query_vector
    )
    ImageEmbedding.create!(
      image_core: first_image,
      snippet: "near duplicate one",
      embedding: [ 0.99, 0.01 ] + Array.new(382, 0.0)
    )
    ImageEmbedding.create!(
      image_core: second_image,
      snippet: "second distinct meme",
      embedding: [ 0.8, 0.2 ] + Array.new(382, 0.0)
    )
    query_embedding = ImageEmbedding.new(
      image_core: first_image,
      snippet: "query",
      embedding: query_vector
    )
    eligible_ids = ImageCore.where(id: [ first_image.id, second_image.id ]).select(:id)

    results = query_embedding.get_neighbor_image_core_ids(limit: 2, image_core_ids: eligible_ids)

    assert_equal [ first_image.id, second_image.id ], results
  end

  test "vector search uses a bounded number of database queries" do
    query_embedding = ImageEmbedding.new(
      image_core: image_cores(:one),
      snippet: "reaction",
      embedding: image_embeddings(:one).embedding
    )
    sql_queries = []
    subscriber = lambda do |_name, _started, _finished, _unique_id, payload|
      sql_queries << payload[:sql] unless payload[:cached] || payload[:name] == "SCHEMA"
    end

    ImageEmbedding.stub(:new, query_embedding) do
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
        ImageSearchQuery.new(query: "reaction", mode: "vector", limit: 2).call
      end
    end

    assert_operator sql_queries.length, :<=, 3, sql_queries.join("\n")
  end

  test "filters keyword results by any selected folder" do
    results = ImageSearchQuery.new(
      query: "image",
      mode: "keyword",
      selected_path_names: [ image_paths(:two).name ]
    ).call

    assert_equal [ image_cores(:three).id, image_cores(:four).id ].sort, results.map(&:id).sort
  end

  test "matches any of several selected folders" do
    results = ImageSearchQuery.new(
      query: "image",
      mode: "keyword",
      selected_path_names: [ image_paths(:one).name, image_paths(:two).name ]
    ).call

    assert_equal image_cores(:one, :two, :three, :four).map(&:id).sort, results.map(&:id).sort
  end

  test "requires both a selected folder and a selected tag" do
    results = ImageSearchQuery.new(
      query: "image",
      mode: "keyword",
      selected_path_names: [ image_paths(:one).name ],
      selected_tag_names: [ "tag_two" ]
    ).call

    assert_equal [ image_cores(:two) ], results

    results = ImageSearchQuery.new(
      query: "image",
      mode: "keyword",
      selected_path_names: [ image_paths(:two).name ],
      selected_tag_names: [ "tag_one" ]
    ).call

    assert_empty results
  end

  test "an unknown folder name matches nothing" do
    results = ImageSearchQuery.new(
      query: "image",
      mode: "keyword",
      selected_path_names: [ "no_such_folder" ]
    ).call

    assert_empty results
  end

  test "filters keyword results by folder before ranking" do
    crowd = image_paths(:one)
    target_path = image_paths(:two)
    ImageSearchQuery::MAX_RESULT_LIMIT.times do |index|
      ImageCore.create!(image_path: crowd, name: "crowd_#{index}.jpg", description: "zebra zebra zebra", status: :not_started)
    end
    target = ImageCore.create!(image_path: target_path, name: "target.jpg", description: "a lone zebra", status: :not_started)

    global = ImageSearchQuery.new(query: "zebra", mode: "keyword", limit: ImageSearchQuery::MAX_RESULT_LIMIT).call
    assert_not_includes global, target

    filtered = ImageSearchQuery.new(
      query: "zebra",
      mode: "keyword",
      selected_path_names: [ target_path.name ],
      limit: ImageSearchQuery::MAX_RESULT_LIMIT
    ).call
    assert_equal [ target ], filtered
  end

  test "filters vector results by folder and tag" do
    query_vector = [ 1.0 ] + Array.new(383, 0.0)
    image_cores(:one, :two, :three).each do |image_core|
      ImageEmbedding.create!(image_core: image_core, snippet: "snippet", embedding: query_vector)
    end

    with_query_vector(query_vector) do
      results = ImageSearchQuery.new(
        query: "reaction",
        mode: "vector",
        selected_path_names: [ image_paths(:one).name ]
      ).call
      assert_equal image_cores(:one, :two).map(&:id).sort, results.map(&:id).sort

      results = ImageSearchQuery.new(
        query: "reaction",
        mode: "vector",
        selected_path_names: [ image_paths(:one).name ],
        selected_tag_names: [ "tag_two" ]
      ).call
      assert_equal [ image_cores(:two) ], results
    end
  end

  test "filters vector results by folder before ranking" do
    crowd = image_paths(:one)
    target_path = image_paths(:two)
    query_vector = [ 1.0 ] + Array.new(383, 0.0)
    ImageSearchQuery::MAX_RESULT_LIMIT.times do |index|
      image_core = ImageCore.create!(image_path: crowd, name: "crowd_#{index}.jpg", description: "crowd", status: :not_started)
      ImageEmbedding.create!(image_core: image_core, snippet: "crowd", embedding: query_vector)
    end
    target = ImageCore.create!(image_path: target_path, name: "target.jpg", description: "target", status: :not_started)
    ImageEmbedding.create!(image_core: target, snippet: "target", embedding: [ 0.1, 0.9 ] + Array.new(382, 0.0))

    with_query_vector(query_vector) do
      global = ImageSearchQuery.new(query: "q", mode: "vector", limit: ImageSearchQuery::MAX_RESULT_LIMIT).call
      assert_not_includes global, target

      filtered = ImageSearchQuery.new(
        query: "q",
        mode: "vector",
        selected_path_names: [ target_path.name ],
        limit: ImageSearchQuery::MAX_RESULT_LIMIT
      ).call
      assert_equal target, filtered.first
      assert filtered.all? { |image_core| image_core.image_path_id == target_path.id }
    end
  end

  test "returns no results for an unsupported mode" do
    results = ImageSearchQuery.new(query: "bunny", mode: "unsupported").call

    assert_empty results
  end

  test "clamps caller supplied limits" do
    results = ImageSearchQuery.new(query: "image", mode: "keyword", limit: 100).call

    assert_operator results.length, :<=, ImageSearchQuery::MAX_RESULT_LIMIT
  end

  test "keyword offset pages continue the ranking without gaps or repeats" do
    all_ids = ImageSearchQuery.new(query: "image", mode: "keyword", limit: 20).call.map(&:id)
    first = ImageSearchQuery.new(query: "image", mode: "keyword", limit: 2).call.map(&:id)
    second = ImageSearchQuery.new(query: "image", mode: "keyword", limit: 2, offset: 2).call.map(&:id)

    assert_equal 4, all_ids.length
    assert_equal all_ids, first + second
  end

  test "keyword paging breaks rank ties by id" do
    # every fixture matches "image" once, so ts_rank ties across the board
    ids = ImageSearchQuery.new(query: "image", mode: "keyword", limit: 20).call.map(&:id)

    assert_equal ids.sort, ids
  end

  test "vector offset pages continue the ranking and tie on id" do
    query_embedding = ImageEmbedding.new(
      image_core: image_cores(:one),
      snippet: "reaction",
      embedding: image_embeddings(:one).embedding
    )

    ImageEmbedding.stub(:new, query_embedding) do
      all_ids = ImageSearchQuery.new(query: "reaction", mode: "vector", limit: 20).call.map(&:id)
      first = ImageSearchQuery.new(query: "reaction", mode: "vector", limit: 2).call.map(&:id)
      second = ImageSearchQuery.new(query: "reaction", mode: "vector", limit: 2, offset: 2).call.map(&:id)

      # fixture embeddings are parallel vectors: every distance ties, so id decides
      assert_equal 3, all_ids.length
      assert_equal all_ids.sort, all_ids
      assert_equal all_ids, first + second
    end
  end

  test "vector neighbors skip the requested number of distinct memes" do
    query_embedding = ImageEmbedding.new(
      image_core: image_cores(:one),
      snippet: "query",
      embedding: [ 1.0 ] + Array.new(383, 0.0)
    )
    ImageEmbedding.delete_all
    [ :one, :two, :three ].each_with_index do |name, index|
      2.times do |chunk|
        ImageEmbedding.create!(
          image_core: image_cores(name),
          snippet: "chunk #{chunk}",
          embedding: [ 1.0 - (index * 0.1), index * 0.1 + chunk * 0.01 ] + Array.new(382, 0.0)
        )
      end
    end

    page = query_embedding.get_neighbor_image_core_ids(limit: 2, offset: 1)

    assert_equal [ image_cores(:two).id, image_cores(:three).id ], page
  end

  test "page reports whether more results exist past the limit" do
    page = ImageSearchQuery.new(query: "image", mode: "keyword", limit: 3).page
    assert_equal 3, page.results.length
    assert page.more

    page = ImageSearchQuery.new(query: "image", mode: "keyword", limit: 2, offset: 2).page
    assert_equal 2, page.results.length
    assert_not page.more
  end

  test "clamps a negative offset to zero" do
    first = ImageSearchQuery.new(query: "image", mode: "keyword", limit: 2).call
    negative = ImageSearchQuery.new(query: "image", mode: "keyword", limit: 2, offset: -5).call

    assert_equal first, negative
  end

  private

    # Keeps the real neighbor SQL but skips the embedding model.
    def with_query_vector(vector, &block)
      query_embedding = ImageEmbedding.new(image_core: image_cores(:one), snippet: "query", embedding: vector)
      query_embedding.define_singleton_method(:compute_embedding) { vector }
      ImageEmbedding.stub(:new, query_embedding, &block)
    end
end
