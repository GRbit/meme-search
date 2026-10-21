require "test_helper"

class Api::V1::FoldersControllerTest < ActionDispatch::IntegrationTest
  setup do
    Rails.application.config.x.api_rate_limit_store.clear
    _, @raw_token = ApiToken.issue!(name: "Folder client", scopes: [ "search:read" ])
  end

  test "lists every folder by name with its meme count" do
    empty = ImagePath.new(name: "Empty/Nested")
    empty.save!(validate: false)

    get api_v1_folders_url, headers: authorization_header

    assert_response :success
    assert_equal(
      [
        { "name" => "Empty/Nested", "meme_count" => 0 },
        { "name" => image_paths(:one).name, "meme_count" => 2 },
        { "name" => image_paths(:two).name, "meme_count" => 2 }
      ],
      response.parsed_body.fetch("data")
    )
    assert_equal 3, response.parsed_body.dig("meta", "count")
  end

  test "lists names that search accepts as folder" do
    get api_v1_folders_url, headers: authorization_header
    name = response.parsed_body.dig("data", 0, "name")

    get api_v1_search_url, params: { q: "image", folder: name }, headers: authorization_header

    assert_response :success
    assert_equal [ name ], response.parsed_body.dig("meta", "folders")
  end

  test "requires a bearer token" do
    get api_v1_folders_url

    assert_response :unauthorized
    assert_equal "unauthorized", response.parsed_body.dig("error", "code")
  end

  test "requires search read scope" do
    _, media_token = ApiToken.issue!(name: "Media only", scopes: [ "media:read" ])

    get api_v1_folders_url, headers: { "Authorization" => "Bearer #{media_token}" }

    assert_response :forbidden
    assert_equal "forbidden", response.parsed_body.dig("error", "code")
  end

  test "rate limits listings per authenticated token" do
    61.times { get api_v1_folders_url, headers: authorization_header }

    assert_response :too_many_requests
    assert_equal "rate_limited", response.parsed_body.dig("error", "code")
  end

  private

    def authorization_header
      { "Authorization" => "Bearer #{@raw_token}" }
    end
end
