require "test_helper"

class Api::V1::SearchControllerTest < ActionDispatch::IntegrationTest
  setup do
    Rails.application.config.x.api_rate_limit_store.clear
    @token, @raw_token = ApiToken.issue!(
      name: "Test client",
      scopes: [ "search:read", "media:read" ]
    )
  end

  test "requires a bearer token" do
    get api_v1_search_url, params: { q: "bunny" }

    assert_response :unauthorized
    assert_equal "unauthorized", response.parsed_body.dig("error", "code")
    assert_match(/^Bearer /, response.headers["WWW-Authenticate"])
  end

  test "returns a stable search response" do
    get api_v1_search_url,
      params: { q: "bunny", mode: "keyword", limit: 5, tag: "tag_two" },
      headers: authorization_header

    assert_response :success
    body = response.parsed_body
    assert_equal "bunny", body.dig("meta", "query")
    assert_equal "keyword", body.dig("meta", "mode")
    assert_equal 1, body.dig("meta", "count")
    assert_equal image_cores(:three).id, body.dig("data", 0, "id")
    assert_equal [ "tag_two" ], body.dig("data", 0, "tags")
    assert_equal content_api_v1_meme_path(image_cores(:three)), body.dig("data", 0, "content_url")
    assert_nil body.dig("data", 0, "image_path")
    assert_equal image_paths(:two).name, body.dig("data", 0, "folder")
    assert_equal "ready", body.dig("data", 0, "description_status")
  end

  test "loads result folders in one query" do
    image_path_queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      image_path_queries << payload[:sql] if payload[:sql].include?("FROM \"image_paths\"")
    end

    get api_v1_search_url, params: { q: "image" }, headers: authorization_header

    assert_response :success
    assert_equal 4, response.parsed_body.dig("meta", "count")
    assert_equal 1, image_path_queries.length, image_path_queries.join("\n")
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  test "computes description status for all results in one embeddings query" do
    embedding_queries = []
    callback = lambda do |*, payload|
      embedding_queries << payload[:sql] if payload[:sql].include?("image_embeddings")
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      get api_v1_search_url, params: { q: "image", limit: 20 }, headers: authorization_header
    end

    assert_response :success
    statuses = response.parsed_body["data"].to_h { |meme| [ meme["id"], meme["description_status"] ] }
    assert_equal "ready", statuses[image_cores(:one).id]
    assert_equal "pending", statuses[image_cores(:four).id]
    assert_equal 1, embedding_queries.length, embedding_queries.join("\n")
  end

  test "rejects invalid queries and modes" do
    get api_v1_search_url, params: { q: "" }, headers: authorization_header
    assert_response :unprocessable_entity
    assert_equal "invalid_query", response.parsed_body.dig("error", "code")

    get api_v1_search_url,
      params: { q: "bunny", mode: "sql" },
      headers: authorization_header
    assert_response :unprocessable_entity
    assert_equal "invalid_mode", response.parsed_body.dig("error", "code")

    get api_v1_search_url,
      params: { q: "bunny", limit: "many" },
      headers: authorization_header
    assert_response :unprocessable_entity
    assert_equal "invalid_limit", response.parsed_body.dig("error", "code")
  end

  test "rejects overlong queries and tags at the documented bounds" do
    get api_v1_search_url,
      params: { q: "q" * (Api::V1::SearchController::QUERY_MAX_LENGTH + 1) },
      headers: authorization_header
    assert_response :unprocessable_entity
    assert_equal "invalid_query", response.parsed_body.dig("error", "code")

    get api_v1_search_url,
      params: {
        q: "bunny",
        tag: "t" * (Api::V1::SearchController::TAG_MAX_LENGTH + 1)
      },
      headers: authorization_header
    assert_response :unprocessable_entity
    assert_equal "invalid_tags", response.parsed_body.dig("error", "code")
  end

  test "rejects result limits outside the documented contract" do
    [ 0, -1, ImageSearchQuery::MAX_RESULT_LIMIT + 1, "many" ].each do |invalid_limit|
      get api_v1_search_url,
        params: { q: "bunny", limit: invalid_limit },
        headers: authorization_header

      assert_response :unprocessable_entity
      assert_equal "invalid_limit", response.parsed_body.dig("error", "code")
    end
  end

  test "accepts repeated tag parameters" do
    get "#{api_v1_search_url}?q=image&tag=tag_one&tag=tag_two",
      headers: authorization_header

    assert_response :success
    assert_equal [ "tag_one", "tag_two" ], response.parsed_body.dig("meta", "tags")
    assert_equal(
      [ image_cores(:one).id, image_cores(:two).id, image_cores(:three).id ].sort,
      response.parsed_body.fetch("data").map { |item| item.fetch("id") }.sort
    )
  end

  test "treats each repeated percent-encoded tag as one exact value" do
    comma_tag = TagName.create!(name: "approval,pending", color: "#123456")
    image_cores(:one).image_tags.create!(tag_name: comma_tag)

    get "#{api_v1_search_url}?q=image&tag=approval%2Cpending&tag=tag_two",
      headers: authorization_header

    assert_response :success
    assert_equal [ "approval,pending", "tag_two" ], response.parsed_body.dig("meta", "tags")
    assert_equal(
      [ image_cores(:one).id, image_cores(:two).id, image_cores(:three).id ].sort,
      response.parsed_body.fetch("data").map { |item| item.fetch("id") }.sort
    )
  end

  test "tag_match defaults to any and is echoed in meta" do
    get "#{api_v1_search_url}?q=image&tag=tag_one&tag=tag_two", headers: authorization_header

    assert_response :success
    assert_equal "any", response.parsed_body.dig("meta", "tag_match")
    assert_equal 3, response.parsed_body.dig("meta", "count")
  end

  test "tag_match all requires every tag before the limit" do
    get "#{api_v1_search_url}?q=image&tag=tag_one&tag=tag_two&tag_match=all&limit=1",
      headers: authorization_header

    assert_response :success
    assert_equal "all", response.parsed_body.dig("meta", "tag_match")
    assert_equal [ image_cores(:two).id ], response.parsed_body.fetch("data").map { |item| item.fetch("id") }
  end

  test "tag_match all works in vector mode" do
    query_embedding = Object.new
    query_embedding.define_singleton_method(:compute_embedding) { Array.new(384, 0.5) }
    query_embedding.define_singleton_method(:get_neighbor_image_core_ids) do |limit:, image_core_ids:|
      image_core_ids.to_a.map(&:id)
    end

    ImageEmbedding.stub(:new, query_embedding) do
      get "#{api_v1_search_url}?q=image&mode=vector&tag=tag_one&tag=tag_two&tag_match=all",
        headers: authorization_header
    end

    assert_response :success
    assert_equal [ image_cores(:two).id ], response.parsed_body.fetch("data").map { |item| item.fetch("id") }
  end

  test "rejects an unknown tag_match" do
    [ "some", "ALL", "all,any" ].each do |value|
      get api_v1_search_url,
        params: { q: "image", tag: "tag_one", tag_match: value },
        headers: authorization_header

      assert_response :unprocessable_entity
      assert_equal "invalid_tag_match", response.parsed_body.dig("error", "code")
    end
  end

  test "rejects excessive tag input" do
    query = ([ "q=bunny" ] + 11.times.map { |index| "tag=tag#{index}" }).join("&")

    get "#{api_v1_search_url}?#{query}", headers: authorization_header

    assert_response :unprocessable_entity
    assert_equal "invalid_tags", response.parsed_body.dig("error", "code")
  end

  test "filters by repeated folder parameters and echoes them" do
    get "#{api_v1_search_url}?q=image&folder=#{image_paths(:two).name}",
      headers: authorization_header

    assert_response :success
    assert_equal [ image_paths(:two).name ], response.parsed_body.dig("meta", "folders")
    assert_equal(
      [ image_cores(:three).id, image_cores(:four).id ].sort,
      response.parsed_body.fetch("data").map { |item| item.fetch("id") }.sort
    )

    get "#{api_v1_search_url}?q=image&folder=#{image_paths(:one).name}&folder=#{image_paths(:two).name}",
      headers: authorization_header

    assert_response :success
    assert_equal image_paths(:one, :two).map(&:name), response.parsed_body.dig("meta", "folders")
    assert_equal 4, response.parsed_body.dig("meta", "count")
  end

  test "echoes no folders when none are requested" do
    get api_v1_search_url, params: { q: "image" }, headers: authorization_header

    assert_response :success
    assert_equal [], response.parsed_body.dig("meta", "folders")
    assert_equal 4, response.parsed_body.dig("meta", "count")
  end

  test "combines folders and tags" do
    get "#{api_v1_search_url}?q=image&folder=#{image_paths(:one).name}&tag=tag_two",
      headers: authorization_header

    assert_response :success
    assert_equal [ image_cores(:two).id ], response.parsed_body.fetch("data").map { |item| item.fetch("id") }
  end

  test "filters vector search by folder" do
    query_vector = [ 1.0 ] + Array.new(383, 0.0)
    image_cores(:one, :three).each do |image_core|
      ImageEmbedding.create!(image_core: image_core, snippet: "snippet", embedding: query_vector)
    end
    query_embedding = ImageEmbedding.new(image_core: image_cores(:one), snippet: "query", embedding: query_vector)
    query_embedding.define_singleton_method(:compute_embedding) { query_vector }

    ImageEmbedding.stub(:new, query_embedding) do
      get api_v1_search_url,
        params: { q: "reaction", mode: "vector", folder: image_paths(:two).name },
        headers: authorization_header
    end

    assert_response :success
    assert_equal [ image_cores(:three).id ], response.parsed_body.fetch("data").map { |item| item.fetch("id") }
  end

  test "matches folder names exactly, including slashes and case" do
    nested = ImagePath.new(name: "Work/Reactions")
    nested.save!(validate: false)
    image_core = ImageCore.create!(image_path: nested, name: "nested.jpg", description: "nested image", status: :not_started)

    get api_v1_search_url, params: { q: "image", folder: "Work/Reactions" }, headers: authorization_header

    assert_response :success
    assert_equal [ image_core.id ], response.parsed_body.fetch("data").map { |item| item.fetch("id") }
    assert_equal "Work/Reactions", response.parsed_body.dig("data", 0, "folder")

    get api_v1_search_url, params: { q: "image", folder: "work/reactions" }, headers: authorization_header

    assert_response :unprocessable_entity
    assert_equal "invalid_folder", response.parsed_body.dig("error", "code")
  end

  test "rejects unknown folders" do
    get "#{api_v1_search_url}?q=image&folder=#{image_paths(:one).name}&folder=no_such_folder",
      headers: authorization_header

    assert_response :unprocessable_entity
    assert_equal "invalid_folder", response.parsed_body.dig("error", "code")
  end

  test "rejects folder input beyond the documented bounds" do
    too_many = Array.new(Api::V1::SearchController::FOLDER_MAX_COUNT + 1) { |index| "folder=f#{index}" }
    get "#{api_v1_search_url}?q=image&#{too_many.join("&")}", headers: authorization_header

    assert_response :unprocessable_entity
    assert_equal "invalid_folder", response.parsed_body.dig("error", "code")

    get api_v1_search_url,
      params: { q: "image", folder: "f" * (Api::V1::SearchController::FOLDER_MAX_LENGTH + 1) },
      headers: authorization_header

    assert_response :unprocessable_entity
    assert_equal "invalid_folder", response.parsed_body.dig("error", "code")
  end

  test "accepts the maximum number of folders" do
    names = Array.new(Api::V1::SearchController::FOLDER_MAX_COUNT) { |index| "bound_#{index}" }
    names.each { |name| ImagePath.new(name: name).save!(validate: false) }

    get "#{api_v1_search_url}?q=image&#{names.map { |name| "folder=#{name}" }.join("&")}",
      headers: authorization_header

    assert_response :success
    assert_equal names, response.parsed_body.dig("meta", "folders")
    assert_equal 0, response.parsed_body.dig("meta", "count")
  end

  test "requires search read scope" do
    _, media_token = ApiToken.issue!(name: "Media only", scopes: [ "media:read" ])

    get api_v1_search_url,
      params: { q: "bunny" },
      headers: { "Authorization" => "Bearer #{media_token}" }

    assert_response :forbidden
    assert_equal "forbidden", response.parsed_body.dig("error", "code")
  end

  test "rejects revoked and expired bearer tokens" do
    revoked, revoked_raw = ApiToken.issue!(name: "Revoked search", scopes: [ "search:read" ])
    revoked.revoke!
    expired, expired_raw = ApiToken.issue!(
      name: "Expired search",
      scopes: [ "search:read" ],
      expires_at: 1.hour.from_now
    )
    expired.update_column(:expires_at, 1.minute.ago)

    [ revoked_raw, expired_raw ].each do |raw_token|
      get api_v1_search_url,
        params: { q: "bunny" },
        headers: { "Authorization" => "Bearer #{raw_token}" }

      assert_response :unauthorized
      assert_equal "unauthorized", response.parsed_body.dig("error", "code")
    end
  end

  test "rate limits searches per authenticated token" do
    61.times do
      get api_v1_search_url,
        params: { q: "bunny" },
        headers: authorization_header
    end

    assert_response :too_many_requests
    assert_equal "rate_limited", response.parsed_body.dig("error", "code")

    _, other_raw_token = ApiToken.issue!(
      name: "Other search client",
      scopes: [ "search:read" ]
    )
    get api_v1_search_url,
      params: { q: "bunny" },
      headers: { "Authorization" => "Bearer #{other_raw_token}" }

    assert_response :success
  end

  test "uses a real rate limit counter when the application cache is null" do
    assert_instance_of ActiveSupport::Cache::NullStore, Rails.cache

    store = Rails.application.config.x.api_rate_limit_store
    assert_not_instance_of ActiveSupport::Cache::NullStore, store

    key = "rate-limit-runtime-proof-#{SecureRandom.hex(8)}"
    assert_equal 1, store.increment(key, 1, expires_in: 1.minute)
    assert_equal 2, store.increment(key, 1, expires_in: 1.minute)
  ensure
    store&.delete(key) if key
  end

  private

    def authorization_header
      { "Authorization" => "Bearer #{@raw_token}" }
    end
end
