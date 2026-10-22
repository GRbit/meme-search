require "test_helper"

class Api::V1::MemesListingTest < ActionDispatch::IntegrationTest
  setup do
    Rails.application.config.x.api_rate_limit_store.clear
    _, @raw_token = ApiToken.issue!(name: "Listing client", scopes: [ "search:read" ])
  end

  test "requires a bearer token" do
    get api_v1_memes_url

    assert_response :unauthorized
    assert_equal "unauthorized", response.parsed_body.dig("error", "code")
  end

  test "requires search read scope" do
    _, media_token = ApiToken.issue!(name: "Media only", scopes: [ "media:read" ])

    get api_v1_memes_url, headers: { "Authorization" => "Bearer #{media_token}" }

    assert_response :forbidden
    assert_equal "forbidden", response.parsed_body.dig("error", "code")
  end

  test "lists every meme ordered by updated_at then id with the search object shape" do
    image_cores(:two).update!(description: "changed later")

    get api_v1_memes_url, headers: authorization_header

    assert_response :success
    body = response.parsed_body
    expected_ids = ImageCore.order(:updated_at, :id).pluck(:id)
    assert_equal expected_ids, body["data"].pluck("id")
    assert_equal image_cores(:two).id, body["data"].last["id"]
    assert_equal 50, body.dig("meta", "limit")
    assert_equal expected_ids.length, body.dig("meta", "count")
    assert_equal false, body.dig("meta", "has_more")
    assert body.dig("meta", "next_cursor").present?

    get api_v1_meme_url(image_cores(:three)), headers: authorization_header
    assert_equal response.parsed_body["data"], body["data"].find { |meme| meme["id"] == image_cores(:three).id }
  end

  test "pages through equal timestamps without skipping or repeating memes" do
    same_time = Time.utc(2024, 5, 1, 12, 0, 0)
    3.times { |index| create_meme("same-#{index}.jpg") }
    ImageCore.update_all(updated_at: same_time)
    expected_ids = ImageCore.order(:id).pluck(:id)

    seen_ids = list_all(limit: 2)

    assert_equal expected_ids, seen_ids
  end

  test "keeps microsecond order inside the cursor" do
    first = create_meme("first.jpg")
    second = create_meme("second.jpg")
    base = Time.utc(2030, 1, 1, 0, 0, 0)
    ImageCore.where.not(id: [ first.id, second.id ]).update_all(updated_at: base - 1.day)
    # The lower id gets the later timestamp, so id order alone would be wrong.
    second.update_columns(updated_at: base + Rational(1, 1_000_000))
    first.update_columns(updated_at: base + Rational(2, 1_000_000))

    seen_ids = list_all(limit: 1)

    assert_equal [ second.id, first.id ], seen_ids.last(2)
  end

  test "an exhausted cursor returns new and changed memes on the next poll" do
    get api_v1_memes_url, params: { limit: 100 }, headers: authorization_header
    cursor = response.parsed_body.dig("meta", "next_cursor")

    get api_v1_memes_url, params: { cursor: cursor }, headers: authorization_header
    assert_response :success
    assert_equal [], response.parsed_body["data"]
    assert_equal 0, response.parsed_body.dig("meta", "count")
    assert_not response.parsed_body["meta"].key?("next_cursor")
    assert_equal false, response.parsed_body.dig("meta", "has_more")

    travel 1.second do
      added = create_meme("added-later.jpg")
      ImageTag.create!(image_core: image_cores(:one), tag_name: tag_names(:two))

      get api_v1_memes_url, params: { cursor: cursor }, headers: authorization_header

      assert_response :success
      assert_equal [ image_cores(:one).id, added.id ].sort, response.parsed_body["data"].pluck("id").sort
      assert_includes response.parsed_body["data"].find { |meme| meme["id"] == image_cores(:one).id }["tags"],
        tag_names(:two).name
    end
  end

  test "reports a meme again once its embeddings make it ready" do
    meme = image_cores(:four)
    meme.image_embeddings.delete_all
    get api_v1_memes_url, params: { limit: 100 }, headers: authorization_header
    cursor = response.parsed_body.dig("meta", "next_cursor")
    assert_equal "pending",
      response.parsed_body["data"].find { |item| item["id"] == meme.id }["description_status"]

    original_model = $embedding_model
    $embedding_model = ->(_text) { Array.new(384, 0.0) }
    travel 1.second do
      meme.refresh_description_embeddings
    end

    get api_v1_memes_url, params: { cursor: cursor }, headers: authorization_header

    assert_equal [ meme.id ], response.parsed_body["data"].pluck("id")
    assert_equal "ready", response.parsed_body.dig("data", 0, "description_status")
  ensure
    $embedding_model = original_model if original_model
  end

  test "accepts limit bounds and rejects values outside them" do
    [ 1, 100 ].each do |limit|
      get api_v1_memes_url, params: { limit: limit }, headers: authorization_header
      assert_response :success
      assert_equal limit, response.parsed_body.dig("meta", "limit")
    end

    get api_v1_memes_url, params: { limit: 1 }, headers: authorization_header
    assert_equal 1, response.parsed_body.dig("meta", "count")
    assert_equal true, response.parsed_body.dig("meta", "has_more")

    [ "0", "101", "-1", "abc", "1.5" ].each do |limit|
      get api_v1_memes_url, params: { limit: limit }, headers: authorization_header
      assert_response :unprocessable_entity, limit
      assert_equal "invalid_limit", response.parsed_body.dig("error", "code")
    end
  end

  test "rejects malformed cursors" do
    malformed = [
      "not base64!",
      Base64.urlsafe_encode64("not json", padding: false),
      Base64.urlsafe_encode64("{}", padding: false),
      Base64.urlsafe_encode64(JSON.generate([ "yesterday", 1 ]), padding: false),
      Base64.urlsafe_encode64(JSON.generate([ "2024-01-01T00:00:00.000000Z", 0 ]), padding: false),
      Base64.urlsafe_encode64(JSON.generate([ "2024-01-01T00:00:00.000000Z", "1" ]), padding: false),
      "a" * 201
    ]

    malformed.each do |cursor|
      get api_v1_memes_url, params: { cursor: cursor }, headers: authorization_header
      assert_response :unprocessable_entity, cursor
      assert_equal "invalid_cursor", response.parsed_body.dig("error", "code")
    end

    get api_v1_memes_url, params: { cursor: [ "a", "b" ] }, headers: authorization_header
    assert_response :unprocessable_entity
    assert_equal "invalid_cursor", response.parsed_body.dig("error", "code")
  end

  test "computes description status for a page in one embeddings query" do
    embedding_queries = []
    callback = lambda do |*, payload|
      embedding_queries << payload[:sql] if payload[:sql].include?("image_embeddings")
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      get api_v1_memes_url, headers: authorization_header
    end

    assert_response :success
    statuses = response.parsed_body["data"].to_h { |meme| [ meme["id"], meme["description_status"] ] }
    assert_equal "ready", statuses[image_cores(:one).id]
    assert_equal "pending", statuses[image_cores(:four).id]
    assert_equal 1, embedding_queries.length, embedding_queries.join("\n")
  end

  test "rate limits listing per token separately from search" do
    61.times { get api_v1_memes_url, headers: authorization_header }

    assert_response :too_many_requests
    assert_equal "rate_limited", response.parsed_body.dig("error", "code")

    get api_v1_search_url, params: { q: "bunny" }, headers: authorization_header
    assert_response :success
  end

  private

    def authorization_header
      { "Authorization" => "Bearer #{@raw_token}" }
    end

    def create_meme(name)
      ImageCore.create!(image_path: image_paths(:one), name: name, status: :not_started)
    end

    def list_all(limit:)
      ids = []
      cursor = nil
      loop do
        params = { limit: limit }
        params[:cursor] = cursor if cursor
        get api_v1_memes_url, params: params, headers: authorization_header
        assert_response :success
        meta = response.parsed_body["meta"]
        ids.concat(response.parsed_body["data"].pluck("id"))
        assert_operator ids.length, :<=, ImageCore.count, "listing repeated memes"
        break unless meta["has_more"]

        cursor = meta.fetch("next_cursor")
      end
      ids
    end
end
