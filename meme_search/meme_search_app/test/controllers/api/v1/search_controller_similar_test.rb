require "test_helper"

class Api::V1::SearchControllerSimilarTest < ActionDispatch::IntegrationTest
  setup do
    Rails.application.config.x.api_rate_limit_store.clear
    ImageEmbedding.delete_all
    @source = image_cores(:one)
    _, @raw_token = ApiToken.issue!(name: "Similar client", scopes: [ "search:read" ])
  end

  test "requires a bearer token" do
    get similar_api_v1_meme_url(@source)

    assert_response :unauthorized
    assert_equal "unauthorized", response.parsed_body.dig("error", "code")
  end

  test "requires search read scope" do
    _, media_token = ApiToken.issue!(name: "Media only", scopes: [ "media:read" ])

    get similar_api_v1_meme_url(@source), headers: { "Authorization" => "Bearer #{media_token}" }

    assert_response :forbidden
    assert_equal "forbidden", response.parsed_body.dig("error", "code")
  end

  test "returns not found for an unknown meme" do
    get similar_api_v1_meme_url(99_999_999), headers: authorization_header

    assert_response :not_found
    assert_equal "not_found", response.parsed_body.dig("error", "code")
  end

  test "rejects result limits outside the documented contract" do
    [ 0, -1, ImageSearchQuery::MAX_RESULT_LIMIT + 1, "many" ].each do |invalid_limit|
      get similar_api_v1_meme_url(@source), params: { limit: invalid_limit }, headers: authorization_header

      assert_response :unprocessable_entity
      assert_equal "invalid_limit", response.parsed_body.dig("error", "code")
    end
  end

  test "returns an empty list while the meme has no embeddings" do
    embed(image_cores(:two), axis_vector(0))

    get similar_api_v1_meme_url(@source), headers: authorization_header

    assert_response :success
    assert_equal [], response.parsed_body.fetch("data")
    assert_equal(
      { "meme_id" => @source.id, "limit" => ImageSearchQuery::DEFAULT_RESULT_LIMIT, "count" => 0 },
      response.parsed_body.fetch("meta")
    )
  end

  test "returns ranked neighbours serialized like search results" do
    embed(@source, axis_vector(0))
    embed(image_cores(:three), axis_vector(0))
    embed(image_cores(:two), axis_vector(1))

    get similar_api_v1_meme_url(@source),
      params: { limit: ImageSearchQuery::MAX_RESULT_LIMIT },
      headers: authorization_header

    assert_response :success
    body = response.parsed_body
    assert_equal [ image_cores(:three).id, image_cores(:two).id ], body.fetch("data").pluck("id")
    assert_equal [ "tag_two" ], body.dig("data", 0, "tags")
    assert_equal content_api_v1_meme_path(image_cores(:three)), body.dig("data", 0, "content_url")
    assert_equal({ "meme_id" => @source.id, "limit" => 20, "count" => 2 }, body.fetch("meta"))

    get similar_api_v1_meme_url(@source), params: { limit: 1 }, headers: authorization_header

    assert_equal [ image_cores(:three).id ], response.parsed_body.fetch("data").pluck("id")
  end

  test "shares the per-token search rate limit" do
    60.times { get api_v1_search_url, params: { q: "bunny" }, headers: authorization_header }
    assert_response :success

    get similar_api_v1_meme_url(@source), headers: authorization_header

    assert_response :too_many_requests
    assert_equal "rate_limited", response.parsed_body.dig("error", "code")
  end

  private

    def authorization_header
      { "Authorization" => "Bearer #{@raw_token}" }
    end

    def embed(image_core, vector)
      ImageEmbedding.create!(image_core: image_core, snippet: image_core.description, embedding: vector)
    end

    def axis_vector(axis)
      Array.new(384, 0.0).tap { |vector| vector[axis] = 1.0 }
    end
end
