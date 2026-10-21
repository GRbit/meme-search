require "test_helper"

class Api::V2::MemesControllerTest < ActionDispatch::IntegrationTest
  JPEG = Base64.decode64("/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAv/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFQEBAQAAAAAAAAAAAAAAAAAAAAX/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIRAxEAPwCwAA//2Q==")
  # Same image with a trailing comment: still a JPEG, different checksum.
  OTHER_JPEG = JPEG + "other".b
  FOLDER = "api-v2-ingest-test"
  ADD_JOB_URL = ImageDescriptionProviders::LocalProvider::ADD_JOB_URL

  setup do
    Rails.application.config.x.api_rate_limit_store.clear
    @token, @raw_token = ApiToken.issue!(name: "Uploader", scopes: [ "media:write" ])

    @upload_dir = Rails.root.join("public", "memes", "direct-uploads")
    FileUtils.mkdir_p(@upload_dir)
    @existing_upload_files = Dir.glob(File.join(@upload_dir, "*")).select { |file| File.file?(file) }

    @folder_dir = Rails.root.join("public", "memes", FOLDER)
    FileUtils.rm_rf(@folder_dir)
    FileUtils.mkdir_p(@folder_dir)
    @folder = ImagePath.create!(name: FOLDER)
  end

  teardown do
    Dir.glob(File.join(@upload_dir, "*")).each do |file|
      File.delete(file) if File.file?(file) && !@existing_upload_files.include?(file)
    end
    image_core_ids = ImageCore.where(image_path: @folder).ids
    ImageDescriptionGenerationAttempt.where(image_core_id: image_core_ids).delete_all
    ImageCore.where(id: image_core_ids).delete_all
    @folder.delete
    FileUtils.rm_rf(@folder_dir)
  end

  test "requires a bearer token" do
    post api_v2_memes_url, params: { files: [ upload("anon.jpg") ] }

    assert_response :unauthorized
    assert_equal "unauthorized", response.parsed_body.dig("error", "code")
    assert_not File.exist?(@upload_dir.join("anon.jpg"))
  end

  test "rejects tokens without media:write, including default read tokens" do
    _, read_raw = ApiToken.issue!(name: "Default reader")

    post api_v2_memes_url, params: { files: [ upload("reader.jpg") ] }, headers: auth(read_raw)

    assert_response :forbidden
    assert_equal(
      { "error" => { "code" => "forbidden", "message" => "This token does not grant media:write." } },
      response.parsed_body
    )
    assert_not File.exist?(@upload_dir.join("reader.jpg"))
  end

  test "stores a file in direct-uploads by default and returns the created meme" do
    ImagePath.find_by(name: "direct-uploads")&.destroy

    post api_v2_memes_url, params: { files: [ upload("api_new.jpg") ] }, headers: auth

    assert_response :success
    image_core = ImagePath.find_by!(name: "direct-uploads").image_cores.find_by!(name: "api_new.jpg")
    assert_equal JPEG, File.binread(@upload_dir.join("api_new.jpg"))
    assert_equal(
      {
        "data" => {
          "created" => [
            {
              "filename" => "api_new.jpg",
              "description_queued" => false,
              "meme" => {
                "id" => image_core.id,
                "filename" => "api_new.jpg",
                "description" => nil,
                "tags" => [],
                "media_type" => "image/jpeg",
                "content_url" => "/api/v1/memes/#{image_core.id}/content"
              }
            }
          ],
          "duplicates" => [],
          "errors" => []
        },
        "meta" => { "folder" => "direct-uploads", "generate_description" => false }
      },
      response.parsed_body
    )
    assert_no_enqueued_jobs
  end

  test "stores files in an existing folder named exactly" do
    post api_v2_memes_url,
      params: { folder: FOLDER, files: [ upload("one.jpg"), upload("two.png", OTHER_JPEG, "image/png") ] },
      headers: auth

    assert_response :success
    body = response.parsed_body
    assert_equal FOLDER, body.dig("meta", "folder")
    assert_equal %w[one.jpg two.png], body.dig("data", "created").map { |entry| entry["filename"] }
    assert_equal @folder.image_cores.where(name: %w[one.jpg two.png]).order(:name).pluck(:id),
      body.dig("data", "created").map { |entry| entry.dig("meme", "id") }
    assert File.exist?(@folder_dir.join("one.jpg"))
    assert_not File.exist?(@upload_dir.join("one.jpg"))
  end

  test "returns a meme id even when the folder is already being scanned" do
    @folder.update_columns(currently_scanning: true)

    post api_v2_memes_url, params: { folder: FOLDER, files: [ upload("during_scan.jpg") ] }, headers: auth

    assert_response :success
    assert_equal @folder.image_cores.find_by!(name: "during_scan.jpg").id,
      response.parsed_body.dig("data", "created", 0, "meme", "id")
  end

  test "rejects an unknown folder before storing anything" do
    ImagePath.find_by(name: "direct-uploads")&.destroy

    [ "missing-folder", FOLDER.upcase, " #{FOLDER}", [ FOLDER ] ].each do |folder|
      assert_no_difference("ImagePath.count") do
        post api_v2_memes_url, params: { folder: folder, files: [ upload("nowhere.jpg") ] }, headers: auth
      end

      assert_response :unprocessable_entity
      assert_equal "invalid_folder", response.parsed_body.dig("error", "code")
    end
    assert_empty Dir.glob(Rails.root.join("public", "memes", "**", "nowhere.jpg"))
  end

  test "rejects a folder whose directory is gone without disclosing its path" do
    FileUtils.rm_rf(@folder_dir)

    post api_v2_memes_url, params: { folder: FOLDER, files: [ upload("gone.jpg") ] }, headers: auth

    assert_response :unprocessable_entity
    assert_equal "invalid_folder", response.parsed_body.dig("error", "code")
    assert_not_includes response.body, Rails.root.to_s
  end

  test "rejects a missing, malformed, or oversized file list" do
    [
      {},
      { files: [] },
      { files: "not-a-file" },
      { files: [ "not-a-file" ] },
      { files: Array.new(Api::V2::MemesController::MAX_FILES + 1) { |index| upload("many_#{index}.jpg") } }
    ].each do |params|
      post api_v2_memes_url, params: params, headers: auth

      assert_response :unprocessable_entity
      assert_equal(
        {
          "error" => {
            "code" => "invalid_files",
            "message" => "files must contain 1 to #{Api::V2::MemesController::MAX_FILES} uploaded files."
          }
        },
        response.parsed_body
      )
    end
    assert_empty Dir.glob(@upload_dir.join("many_*"))
  end

  test "accepts exactly the maximum number of files" do
    files = Array.new(Api::V2::MemesController::MAX_FILES) { |index| upload("max_#{index}.jpg", JPEG + index.to_s) }

    post api_v2_memes_url, params: { folder: FOLDER, files: files }, headers: auth

    assert_response :success
    assert_equal Api::V2::MemesController::MAX_FILES, response.parsed_body.dig("data", "created").length
  end

  test "rejects a generate_description value other than true or false" do
    [ "yes", "1", "TRUE", "" ].each do |value|
      post api_v2_memes_url,
        params: { generate_description: value, files: [ upload("flag.jpg") ] },
        headers: auth

      assert_response :unprocessable_entity
      assert_equal "invalid_generate_description", response.parsed_body.dig("error", "code")
    end
    assert_not File.exist?(@upload_dir.join("flag.jpg"))
  end

  test "reports per-file errors next to created memes" do
    big = upload("big.jpg", "x" * (ImageUploadService::MAX_FILE_SIZE + 1))

    post api_v2_memes_url,
      params: {
        folder: FOLDER,
        files: [ upload("fine.jpg"), upload("fake.jpg", "not an image"), upload("notes.txt", JPEG, "text/plain"), big ]
      },
      headers: auth

    assert_response :success
    body = response.parsed_body
    assert_equal [ "fine.jpg" ], body.dig("data", "created").map { |entry| entry["filename"] }
    assert_equal(
      [
        {
          "filename" => "fake.jpg",
          "error" => {
            "code" => "invalid_image",
            "message" => "Invalid image file. File content does not match image format."
          }
        },
        {
          "filename" => "notes.txt",
          "error" => {
            "code" => "unsupported_file_type",
            "message" => "Invalid file type. Allowed: .jpg, .jpeg, .png, .webp, .gif"
          }
        },
        {
          "filename" => "big.jpg",
          "error" => { "code" => "file_too_large", "message" => "File size exceeds maximum allowed (10MB)" }
        }
      ],
      body.dig("data", "errors")
    )
    assert_equal [ "fine.jpg" ], Dir.children(@folder_dir)
  end

  test "hides unexpected storage error details" do
    original_open = File.method(:open)
    failing_open = lambda do |path, *args, **kwargs, &block|
      raise IOError, "boom in #{path}" if path.to_s.end_with?("broken.jpg")

      original_open.call(path, *args, **kwargs, &block)
    end

    File.stub(:open, failing_open) do
      post api_v2_memes_url, params: { folder: FOLDER, files: [ upload("broken.jpg") ] }, headers: auth
    end

    assert_response :success
    assert_equal(
      [
        {
          "filename" => "broken.jpg",
          "error" => { "code" => "storage_failed", "message" => "The file could not be stored." }
        }
      ],
      response.parsed_body.dig("data", "errors")
    )
    assert_not_includes response.body, @folder_dir.to_s
  end

  test "reports a file already in the target folder as a duplicate instead of storing it" do
    File.binwrite(@folder_dir.join("existing.jpg"), JPEG)
    @folder.scan_and_update!
    existing = @folder.image_cores.find_by!(name: "existing.jpg")
    File.binwrite(@folder_dir.join("unindexed.jpg"), OTHER_JPEG)

    post api_v2_memes_url,
      params: { folder: FOLDER, files: [ upload("again.jpg"), upload("again_unindexed.jpg", OTHER_JPEG) ] },
      headers: auth

    assert_response :success
    body = response.parsed_body
    assert_empty body.dig("data", "created")
    assert_equal [ "again.jpg", "again_unindexed.jpg" ],
      body.dig("data", "duplicates").map { |entry| entry["filename"] }
    assert_equal existing.id, body.dig("data", "duplicates", 0, "meme", "id")
    assert_nil body.dig("data", "duplicates", 1, "meme")
    assert_equal %w[existing.jpg unindexed.jpg], Dir.children(@folder_dir).sort
  end

  test "the same bytes in another folder are not a duplicate" do
    File.binwrite(@upload_dir.join("elsewhere_copy.jpg"), JPEG)

    post api_v2_memes_url, params: { folder: FOLDER, files: [ upload("copy.jpg") ] }, headers: auth

    assert_response :success
    assert_equal [ "copy.jpg" ], response.parsed_body.dig("data", "created").map { |entry| entry["filename"] }
    assert_empty response.parsed_body.dig("data", "duplicates")
  end

  test "a file repeated in one request is stored once" do
    post api_v2_memes_url,
      params: { folder: FOLDER, files: [ upload("first.jpg"), upload("second.jpg") ] },
      headers: auth

    assert_response :success
    body = response.parsed_body
    created_id = body.dig("data", "created", 0, "meme", "id")
    assert_equal [ "first.jpg" ], body.dig("data", "created").map { |entry| entry["filename"] }
    assert_equal [ { "filename" => "second.jpg", "id" => created_id } ],
      body.dig("data", "duplicates").map { |entry| { "filename" => entry["filename"], "id" => entry.dig("meme", "id") } }
    assert_equal [ "first.jpg" ], Dir.children(@folder_dir)
  end

  test "generate_description=true queues the local provider for each created meme" do
    stub_request(:post, ADD_JOB_URL).to_return(status: 200, body: "{}")

    post api_v2_memes_url,
      params: { folder: FOLDER, generate_description: "true", files: [ upload("describe.jpg") ] },
      headers: auth

    assert_response :success
    body = response.parsed_body
    assert_equal true, body.dig("meta", "generate_description")
    assert_equal true, body.dig("data", "created", 0, "description_queued")
    image_core = ImageCore.find(body.dig("data", "created", 0, "meme", "id"))
    assert_predicate image_core, :in_queue?
    assert_requested :post, ADD_JOB_URL, times: 1
  end

  test "a meme is still created when its description cannot be queued" do
    stub_request(:post, ADD_JOB_URL).to_return(status: 503)

    post api_v2_memes_url,
      params: { folder: FOLDER, generate_description: "true", files: [ upload("offline.jpg") ] },
      headers: auth

    assert_response :success
    assert_equal false, response.parsed_body.dig("data", "created", 0, "description_queued")
    assert @folder.image_cores.exists?(name: "offline.jpg")
  end

  test "generate_description=true enqueues the job for a non-queued provider" do
    DescriptionProviderSetting.current.update!(provider: "openai")

    post api_v2_memes_url,
      params: { folder: FOLDER, generate_description: "true", files: [ upload("openai.jpg") ] },
      headers: auth

    assert_response :success
    image_core = @folder.image_cores.find_by!(name: "openai.jpg")
    assert_predicate image_core, :in_queue?
    assert_enqueued_jobs 1, only: GenerateImageDescriptionJob
    assert_equal true, response.parsed_body.dig("data", "created", 0, "description_queued")
  end

  test "generate_description=false queues nothing" do
    post api_v2_memes_url,
      params: { folder: FOLDER, generate_description: "false", files: [ upload("quiet.jpg") ] },
      headers: auth

    assert_response :success
    assert_equal false, response.parsed_body.dig("meta", "generate_description")
    assert_no_enqueued_jobs
    assert_not_requested :post, ADD_JOB_URL
  end

  test "rate limits uploads per token separately from search" do
    _, both_raw = ApiToken.issue!(name: "Bot", scopes: [ "search:read", "media:write" ])

    Api::V2::MemesController::RATE_LIMIT.times do
      post api_v2_memes_url, headers: auth(both_raw)
      assert_response :unprocessable_entity
    end
    post api_v2_memes_url, headers: auth(both_raw)

    assert_response :too_many_requests
    assert_equal(
      { "error" => { "code" => "rate_limited", "message" => "Too many upload requests. Try again shortly." } },
      response.parsed_body
    )

    get api_v1_search_url, params: { q: "bunny" }, headers: auth(both_raw)
    assert_response :success

    post api_v2_memes_url, headers: auth
    assert_response :unprocessable_entity
  end

  test "exhausting the search limit does not block uploads" do
    _, both_raw = ApiToken.issue!(name: "Bot", scopes: [ "search:read", "media:write" ])
    61.times { get api_v1_search_url, params: { q: "bunny" }, headers: auth(both_raw) }
    assert_response :too_many_requests

    post api_v2_memes_url, params: { folder: FOLDER, files: [ upload("after_search.jpg") ] }, headers: auth(both_raw)

    assert_response :success
  end

  test "logs one audit line per file with the token prefix but never the token" do
    log = StringIO.new
    original_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(log)

    post api_v2_memes_url,
      params: { folder: FOLDER, files: [ upload("audit.jpg"), upload("audit\nforged.jpg", "not an image") ] },
      headers: auth

    assert_response :success
    lines = log.string.lines.grep(/\[API v2 ingest\]/)
    assert_equal 2, lines.length
    assert_includes lines[0], "token=#{@token.token_prefix}"
    assert_includes lines[0], "file=\"audit.jpg\""
    assert_includes lines[0], "size=#{JPEG.bytesize}"
    assert_includes lines[0], "result=created"
    assert_includes lines[1], "file=\"audit\\nforged.jpg\""
    assert_includes lines[1], "result=invalid_image"
    assert_not_includes log.string, @raw_token
  ensure
    Rails.logger = original_logger
  end

  private

    def upload(filename, content = JPEG, mime_type = "image/jpeg")
      Rack::Test::UploadedFile.new(StringIO.new(content), mime_type, original_filename: filename)
    end

    def auth(raw_token = @raw_token)
      { "Authorization" => "Bearer #{raw_token}" }
    end
end
