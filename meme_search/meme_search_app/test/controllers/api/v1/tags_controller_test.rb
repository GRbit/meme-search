require "test_helper"

class Api::V1::TagsControllerTest < ActionDispatch::IntegrationTest
  setup do
    Rails.application.config.x.api_rate_limit_store.clear
    _, @raw_token = ApiToken.issue!(name: "Tags client", scopes: [ "search:read" ])
  end

  test "requires a bearer token" do
    get api_v1_tags_url

    assert_response :unauthorized
    assert_equal "unauthorized", response.parsed_body.dig("error", "code")
  end

  test "requires search read scope" do
    _, media_token = ApiToken.issue!(name: "Media only", scopes: [ "media:read" ])

    get api_v1_tags_url, headers: { "Authorization" => "Bearer #{media_token}" }

    assert_response :forbidden
    assert_equal "forbidden", response.parsed_body.dig("error", "code")
  end

  test "lists tag names with meme counts ordered by name" do
    get api_v1_tags_url, headers: authorization_header

    assert_response :success
    assert_equal(
      [ { "name" => "tag_one", "meme_count" => 2 }, { "name" => "tag_two", "meme_count" => 2 } ],
      response.parsed_body.fetch("data")
    )
    assert_equal({ "count" => 2 }, response.parsed_body.fetch("meta"))
  end

  test "omits tags that no meme carries and counts each meme once" do
    TagName.create!(name: "unused", color: "#123456")
    image_cores(:one).image_tags.create!(tag_name: tag_names(:one))

    get api_v1_tags_url, headers: authorization_header

    names = response.parsed_body.fetch("data").map { |tag| tag.fetch("name") }
    assert_equal %w[tag_one tag_two], names
    assert_equal 2, response.parsed_body.dig("data", 0, "meme_count")
  end

  test "returns an empty list when no tag is in use" do
    ImageTag.delete_all

    get api_v1_tags_url, headers: authorization_header

    assert_response :success
    assert_equal [], response.parsed_body.fetch("data")
    assert_equal 0, response.parsed_body.dig("meta", "count")
  end

  test "rate limits listings per authenticated token" do
    61.times { get api_v1_tags_url, headers: authorization_header }

    assert_response :too_many_requests
    assert_equal "rate_limited", response.parsed_body.dig("error", "code")
  end

  private

    def authorization_header
      { "Authorization" => "Bearer #{@raw_token}" }
    end
end
