require "test_helper"
require "yaml"

class ApiV2OpenapiTest < ActionDispatch::IntegrationTest
  setup do
    Rails.application.config.x.api_rate_limit_store.clear
    contract_path = Rails.root.join("..", "..", "docs", "api-v2-openapi.yml").cleanpath
    @contract = YAML.safe_load_file(contract_path)
    _, @raw_token = ApiToken.issue!(name: "v2 contract test", scopes: ApiToken::WRITE_SCOPES)
    @upload_dir = Rails.root.join("public", "memes", "direct-uploads")
    FileUtils.mkdir_p(@upload_dir)
    @existing_upload_files = Dir.glob(File.join(@upload_dir, "*"))
  end

  teardown do
    (Dir.glob(File.join(@upload_dir, "*")) - @existing_upload_files).each { |file| File.delete(file) }
  end

  test "documents every v2 route and its limits" do
    v2_routes = Rails.application.routes.routes.filter_map do |route|
      path = route.path.spec.to_s.delete_suffix("(.:format)")
      [ path, route.verb ] if path.start_with?("/api/v2/")
    end

    assert_equal [ [ "/api/v2/memes", "POST" ] ], v2_routes
    assert_equal [ "/api/v2/memes" ], @contract.fetch("paths").keys
    assert_equal ApiToken::WRITE_SCOPES, @contract.dig("info", "x-token-scopes")
    assert_equal "media:write", operation.fetch("x-required-scope")
    assert_equal Api::V2::MemesController::RATE_LIMIT, operation.dig("x-rate-limit", "requests")
    assert_equal 60, operation.dig("x-rate-limit", "window-seconds")
    assert_equal Api::V2::MemesController::MAX_FILES, form_properties.dig("files[]", "maxItems")
    assert_equal Api::V2::MemesController::BOOLEANS.keys, form_properties.dig("generate_description", "enum")
    assert_equal %w[200 401 403 422 429], operation.fetch("responses").keys.sort
    assert_equal(
      Api::V2::MemesController::CLIENT_ERROR_CODES.values + [ "storage_failed" ],
      schema("FailedFile").dig("properties", "error", "properties", "code", "enum")
    )
  end

  test "a live response carries exactly the documented fields" do
    jpeg = Base64.decode64("/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAv/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFQEBAQAAAAAAAAAAAAAAAAAAAAX/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIRAxEAPwCwAA//2Q==")
    files = [
      Rack::Test::UploadedFile.new(StringIO.new(jpeg), "image/jpeg", original_filename: "contract.jpg"),
      Rack::Test::UploadedFile.new(StringIO.new(jpeg), "image/jpeg", original_filename: "contract_again.jpg"),
      Rack::Test::UploadedFile.new(StringIO.new("text"), "image/jpeg", original_filename: "contract_bad.jpg")
    ]

    post api_v2_memes_url, params: { files: files }, headers: { "Authorization" => "Bearer #{@raw_token}" }

    assert_response :success
    body = response.parsed_body
    assert_documented_keys "UploadResponse", body
    assert_equal schema("UploadResponse").dig("properties", "data", "required").sort, body["data"].keys.sort
    assert_equal schema("UploadResponse").dig("properties", "meta", "required").sort, body["meta"].keys.sort
    assert_documented_keys "CreatedFile", body.dig("data", "created", 0)
    assert_documented_keys "DuplicateFile", body.dig("data", "duplicates", 0)
    assert_documented_keys "FailedFile", body.dig("data", "errors", 0)
    assert_documented_keys "Meme", body.dig("data", "created", 0, "meme")
    assert_equal Api::V1::MemeSerializer.new(image_cores(:one), content_url: "x", embedded: false).as_json.keys.map(&:to_s).sort,
      schema("Meme").fetch("required").sort
  end

  private

    def operation
      @contract.dig("paths", "/api/v2/memes", "post")
    end

    def form_properties
      operation.dig("requestBody", "content", "multipart/form-data", "schema", "properties")
    end

    def schema(name)
      @contract.dig("components", "schemas", name)
    end

    def assert_documented_keys(name, value)
      assert_equal schema(name).fetch("required").sort, value.keys.sort, "#{name} fields drifted from the contract"
    end
end
