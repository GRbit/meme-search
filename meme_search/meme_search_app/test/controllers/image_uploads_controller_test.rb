require "test_helper"
require "minitest/mock"
require_relative "../services/image_description_providers/gif_test_data"

class ImageUploadsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @upload_dir = Rails.root.join("public", "memes", "direct-uploads")
    FileUtils.mkdir_p(@upload_dir)
    @existing_upload_files = Dir.glob(File.join(@upload_dir, "*")).select { |file| File.file?(file) }
  end

  def teardown
    # Clean up test uploads
    Dir.glob(File.join(@upload_dir, "*")).each do |file|
      File.delete(file) if File.file?(file) && !@existing_upload_files.include?(file)
    end
  end

  # Helper to create a test image file upload
  def create_test_image(filename: "test.jpg", content: nil, mime_type: "image/jpeg")
    # Create a minimal valid JPEG (1x1 pixel) if no content provided
    if content.nil?
      # Base64 decoded 1x1 pixel JPEG
      content = Base64.decode64("/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAv/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFQEBAQAAAAAAAAAAAAAAAAAAAAX/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIRAxEAPwCwAA//2Q==")
    end

    Rack::Test::UploadedFile.new(
      StringIO.new(content),
      mime_type,
      original_filename: filename
    )
  end

  # GET /image_uploads/new tests
  test "should get new" do
    get new_image_upload_url
    assert_response :success
  end

  # POST /image_uploads tests
  test "should create upload and ensure direct-uploads ImagePath" do
    # Ensure the direct-uploads path doesn't exist yet
    ImagePath.find_by(name: "direct-uploads")&.destroy

    file = create_test_image(filename: "test_upload.jpg")

    assert_difference("ImagePath.count", 1) do
      post image_uploads_url, params: { files: [ file ] }
    end

    assert_response :success
    assert ImagePath.exists?(name: "direct-uploads")

    # Verify file was saved
    uploaded_file_path = File.join(@upload_dir, "test_upload.jpg")
    assert File.exist?(uploaded_file_path)
  end

  test "should upload multiple files" do
    ImagePath.ensure_direct_uploads_path!

    file1 = create_test_image(filename: "image1.jpg")
    file2 = create_test_image(filename: "image2.jpg")

    post image_uploads_url, params: { files: [ file1, file2 ] }
    assert_response :success

    # Verify both files were saved
    assert File.exist?(File.join(@upload_dir, "image1.jpg"))
    assert File.exist?(File.join(@upload_dir, "image2.jpg"))

    # Verify response JSON
    json_response = JSON.parse(response.body)
    assert_equal 2, json_response["success"].length
  end

  test "should reject files over 10MB" do
    ImagePath.ensure_direct_uploads_path!

    # Create a file that's over 10MB
    large_content = "x" * (11 * 1024 * 1024)  # 11MB
    file = create_test_image(filename: "large.jpg", content: large_content)

    post image_uploads_url, params: { files: [ file ] }
    assert_response :unprocessable_entity

    json_response = JSON.parse(response.body)
    assert json_response["errors"].any?
    assert_match(/exceeds maximum/, json_response["errors"].first["error"])
  end

  test "should reject invalid file types" do
    ImagePath.ensure_direct_uploads_path!

    invalid_file = Rack::Test::UploadedFile.new(
      StringIO.new("fake pdf content"),
      "application/pdf",
      original_filename: "document.pdf"
    )

    post image_uploads_url, params: { files: [ invalid_file ] }
    assert_response :unprocessable_entity

    json_response = JSON.parse(response.body)
    assert json_response["errors"].any?
    assert_match(/Invalid file type/, json_response["errors"].first["error"])
  end

  test "should sanitize filenames" do
    ImagePath.ensure_direct_uploads_path!

    # Test file with special characters
    file = create_test_image(filename: "../../../etc/passwd.jpg")

    post image_uploads_url, params: { files: [ file ] }
    assert_response :success

    # Verify file was saved with sanitized name (should strip path traversal)
    json_response = JSON.parse(response.body)
    sanitized_filename = json_response["success"].first["filename"]

    # Should not contain path traversal
    assert_not_includes sanitized_filename, ".."
    assert_not_includes sanitized_filename, "/"
  end

  test "should return error when no files provided" do
    post image_uploads_url, params: {}
    assert_response :unprocessable_entity

    json_response = JSON.parse(response.body)
    assert_match(/No files selected/, json_response["error"])
  end

  test "should trigger ImagePath scan after upload" do
    ImagePath.ensure_direct_uploads_path!
    direct_uploads_path = ImagePath.find_by(name: "direct-uploads")

    # Record initial ImageCore count
    initial_count = ImageCore.where(image_path: direct_uploads_path).count

    file = create_test_image(filename: "scan_test.jpg")

    post image_uploads_url, params: { files: [ file ] }
    assert_response :success

    # Verify scan ran and created ImageCore record
    direct_uploads_path.reload
    final_count = ImageCore.where(image_path: direct_uploads_path).count
    assert_equal initial_count + 1, final_count
  end

  test "should preserve and scan an animated GIF upload" do
    ImagePath.ensure_direct_uploads_path!
    gif_content = Base64.strict_decode64(GifTestData::ANIMATED_GIF_BASE64)
    file = create_test_image(filename: "animated.gif", content: gif_content, mime_type: "image/gif")

    post image_uploads_url, params: { files: [ file ] }
    assert_response :success

    json_response = JSON.parse(response.body)
    saved_filename = json_response.fetch("success").first.fetch("filename")
    saved_path = @upload_dir.join(saved_filename)

    assert_equal gif_content, File.binread(saved_path)
    assert ImageCore.exists?(image_path: ImagePath.find_by!(name: "direct-uploads"), name: saved_filename)
  end

  test "should discover an animated GIF in a configured directory" do
    directory_name = "gif-scan-test"
    directory = Rails.root.join("public", "memes", directory_name)
    FileUtils.mkdir_p(directory)
    File.binwrite(directory.join("discovered.gif"), Base64.strict_decode64(GifTestData::ANIMATED_GIF_BASE64))

    image_path = ImagePath.create!(name: directory_name)

    assert image_path.image_cores.exists?(name: "discovered.gif")
  ensure
    image_path&.image_cores&.delete_all
    image_path&.destroy
    FileUtils.rm_rf(directory) if directory
  end

  test "should reject non-image content with a GIF extension" do
    ImagePath.ensure_direct_uploads_path!
    fake_gif = Rack::Test::UploadedFile.new(
      StringIO.new("not a gif"),
      "image/gif",
      original_filename: "fake.gif"
    )

    post image_uploads_url, params: { files: [ fake_gif ] }
    assert_response :unprocessable_entity

    json_response = JSON.parse(response.body)
    assert_match(/Invalid image file/, json_response.fetch("errors").first.fetch("error"))
  end

  test "should handle mixed valid and invalid files" do
    ImagePath.ensure_direct_uploads_path!

    valid_file = create_test_image(filename: "valid.jpg")
    invalid_file = Rack::Test::UploadedFile.new(
      StringIO.new("text content"),
      "text/plain",
      original_filename: "invalid.txt"
    )

    post image_uploads_url, params: { files: [ valid_file, invalid_file ] }
    assert_response :unprocessable_entity

    json_response = JSON.parse(response.body)
    assert_equal 1, json_response["success"].length
    assert_equal 1, json_response["errors"].length
  end

  test "should handle duplicate filenames by appending timestamp" do
    ImagePath.ensure_direct_uploads_path!

    # Upload first file
    file1 = create_test_image(filename: "duplicate.jpg")
    post image_uploads_url, params: { files: [ file1 ] }
    assert_response :success

    json_response1 = JSON.parse(response.body)
    first_filename = json_response1["success"].first["filename"]

    # Upload second file with same name (use default valid JPEG)
    file2 = create_test_image(filename: "duplicate.jpg")
    post image_uploads_url, params: { files: [ file2 ] }
    assert_response :success

    json_response2 = JSON.parse(response.body)
    second_filename = json_response2["success"].first["filename"]

    # Filenames should be different (second has timestamp)
    assert_not_equal first_filename, second_filename
    assert_match(/duplicate_\d+\.jpg/, second_filename)

    # Both files should exist
    assert File.exist?(File.join(@upload_dir, first_filename))
    assert File.exist?(File.join(@upload_dir, second_filename))
  end

  test "should reject file with invalid MIME type despite valid extension" do
    ImagePath.ensure_direct_uploads_path!

    # Create a text file disguised as a .jpg
    fake_image = Rack::Test::UploadedFile.new(
      StringIO.new("This is not an image"),
      "text/plain",
      original_filename: "fake.jpg"
    )

    post image_uploads_url, params: { files: [ fake_image ] }
    assert_response :unprocessable_entity

    json_response = JSON.parse(response.body)
    assert json_response["errors"].any?
    assert_match(/Invalid image file/, json_response["errors"].first["error"])
  end

  test "should preserve unicode characters in filenames" do
    ImagePath.ensure_direct_uploads_path!

    # Test with various unicode filenames
    unicode_file = create_test_image(filename: "中文图片.jpg")
    post image_uploads_url, params: { files: [ unicode_file ] }
    assert_response :success

    json_response = JSON.parse(response.body)
    filename = json_response["success"].first["filename"]

    # Filename should contain unicode characters
    assert_match(/中文图片/, filename)
  end

  # The tests below pin the exact response bodies, status codes and side effects of the
  # web upload so the upload logic can move out of the controller without changing them.

  test "returns the exact success body with the scan result" do
    ImagePath.ensure_direct_uploads_path!
    file = create_test_image(filename: "exact.jpg")
    size = file.size

    post image_uploads_url, params: { files: [ file ] }

    assert_response :ok
    assert_equal "application/json; charset=utf-8", response.content_type
    expected = {
      "success" => [
        { "success" => true, "filename" => "exact.jpg", "size" => size, "path" => "/memes/direct-uploads/exact.jpg" }
      ],
      "errors" => [],
      "scan" => { "added" => 1, "removed" => 0, "unsafe" => 0 }
    }
    assert_equal expected.to_json, response.body
  end

  test "returns the exact no-files body without creating the direct-uploads path" do
    ImagePath.find_by(name: "direct-uploads")&.destroy

    assert_no_difference("ImagePath.count") do
      post image_uploads_url, params: {}
    end

    assert_response :unprocessable_entity
    assert_equal({ error: "No files selected" }.to_json, response.body)
  end

  test "creates the direct-uploads path and skips the scan when every file is rejected" do
    ImagePath.find_by(name: "direct-uploads")&.destroy
    invalid_file = Rack::Test::UploadedFile.new(StringIO.new("pdf"), "application/pdf", original_filename: "doc.pdf")

    assert_difference("ImagePath.count", 1) do
      post image_uploads_url, params: { files: [ invalid_file ] }
    end

    assert_response :unprocessable_entity
    expected = {
      "success" => [],
      "errors" => [
        { "success" => false, "filename" => "doc.pdf", "error" => "Invalid file type. Allowed: .jpg, .jpeg, .png, .webp, .gif" }
      ]
    }
    assert_equal expected.to_json, response.body
    assert_nil ImagePath.find_by!(name: "direct-uploads").last_scanned_at
  end

  test "returns both lists and the scan when files are mixed" do
    ImagePath.ensure_direct_uploads_path!
    valid_file = create_test_image(filename: "mixed_ok.jpg")
    size = valid_file.size
    fake_image = Rack::Test::UploadedFile.new(StringIO.new("not an image"), "image/jpeg", original_filename: "mixed_bad.jpg")

    post image_uploads_url, params: { files: [ valid_file, fake_image ] }

    assert_response :unprocessable_entity
    expected = {
      "success" => [
        { "success" => true, "filename" => "mixed_ok.jpg", "size" => size, "path" => "/memes/direct-uploads/mixed_ok.jpg" }
      ],
      "errors" => [
        { "success" => false, "filename" => "mixed_bad.jpg", "error" => "Invalid image file. File content does not match image format." }
      ],
      "scan" => { "added" => 1, "removed" => 0, "unsafe" => 0 }
    }
    assert_equal expected.to_json, response.body
  end

  test "returns a null scan when the direct-uploads path is already scanning" do
    ImagePath.ensure_direct_uploads_path!.update_columns(currently_scanning: true)

    post image_uploads_url, params: { files: [ create_test_image(filename: "while_scanning.jpg") ] }

    assert_response :ok
    json_response = JSON.parse(response.body)
    assert json_response.key?("scan")
    assert_nil json_response["scan"]
    assert File.exist?(File.join(@upload_dir, "while_scanning.jpg"))
  ensure
    ImagePath.find_by(name: "direct-uploads")&.update_columns(currently_scanning: false)
  end

  test "accepts a file of exactly 10MB and rejects one byte more" do
    ImagePath.ensure_direct_uploads_path!
    jpeg = create_test_image.read
    limit = 10.megabytes

    post image_uploads_url, params: { files: [ create_test_image(filename: "at_limit.jpg", content: jpeg + ("x" * (limit - jpeg.bytesize))) ] }
    assert_response :ok
    assert_equal limit, File.size(File.join(@upload_dir, "at_limit.jpg"))

    post image_uploads_url, params: { files: [ create_test_image(filename: "over_limit.jpg", content: jpeg + ("x" * (limit + 1 - jpeg.bytesize))) ] }
    assert_response :unprocessable_entity
    assert_equal(
      { "success" => false, "filename" => "over_limit.jpg", "error" => "File size exceeds maximum allowed (10MB)" },
      JSON.parse(response.body).fetch("errors").first
    )
  end

  test "accepts an upper-case extension and keeps the name as given" do
    ImagePath.ensure_direct_uploads_path!

    post image_uploads_url, params: { files: [ create_test_image(filename: "Shout.JPG") ] }

    assert_response :ok
    assert_equal "Shout.JPG", JSON.parse(response.body).fetch("success").first.fetch("filename")
    assert File.exist?(File.join(@upload_dir, "Shout.JPG"))
  end

  test "collapses whitespace in file names" do
    ImagePath.ensure_direct_uploads_path!

    post image_uploads_url, params: { files: [ create_test_image(filename: "  my    spaced   meme.jpg") ] }

    assert_response :ok
    entry = JSON.parse(response.body).fetch("success").first
    assert_equal "my spaced meme.jpg", entry.fetch("filename")
    assert_equal "/memes/direct-uploads/my spaced meme.jpg", entry.fetch("path")
  end

  test "checks the extension before sanitizing, so a trailing space is rejected" do
    ImagePath.ensure_direct_uploads_path!

    post image_uploads_url, params: { files: [ create_test_image(filename: "trailing.jpg ") ] }

    assert_response :unprocessable_entity
    assert_equal "trailing.jpg ", JSON.parse(response.body).fetch("errors").first.fetch("filename")
  end

  test "names a duplicate with the current unix timestamp" do
    ImagePath.ensure_direct_uploads_path!
    File.binwrite(File.join(@upload_dir, "dup_time.jpg"), "existing")

    travel_to Time.zone.at(1_700_000_000) do
      post image_uploads_url, params: { files: [ create_test_image(filename: "dup_time.jpg") ] }
    end

    assert_response :ok
    entry = JSON.parse(response.body).fetch("success").first
    assert_equal "dup_time_1700000000.jpg", entry.fetch("filename")
    assert_equal "/memes/direct-uploads/dup_time_1700000000.jpg", entry.fetch("path")
    assert_equal "existing", File.binread(File.join(@upload_dir, "dup_time.jpg"))
  end

  test "reports a MIME detection failure with its message" do
    ImagePath.ensure_direct_uploads_path!

    Marcel::MimeType.stub(:for, ->(*) { raise "detector broke" }) do
      post image_uploads_url, params: { files: [ create_test_image(filename: "detect.jpg") ] }
    end

    assert_response :unprocessable_entity
    assert_equal(
      { "success" => false, "filename" => "detect.jpg", "error" => "Failed to validate file type: detector broke" },
      JSON.parse(response.body).fetch("errors").first
    )
  end

  {
    Errno::ENOSPC => "Server disk is full. Please free up space or contact administrator.",
    Errno::EACCES => "Cannot write to uploads directory. Check Docker volume mount permissions in docker-compose.yml",
    IOError => "Failed to save file: write broke"
  }.each do |error_class, message|
    test "reports #{error_class} while writing the upload" do
      ImagePath.ensure_direct_uploads_path!
      original_open = File.method(:open)
      failing_open = lambda do |path, *args, **kwargs, &block|
        raise error_class, "write broke" if path.to_s.include?("direct-uploads")

        original_open.call(path, *args, **kwargs, &block)
      end

      File.stub(:open, failing_open) do
        post image_uploads_url, params: { files: [ create_test_image(filename: "write_fail.jpg") ] }
      end

      assert_response :unprocessable_entity
      assert_equal(
        { "success" => false, "filename" => "write_fail.jpg", "error" => message },
        JSON.parse(response.body).fetch("errors").first
      )
      assert_not File.exist?(File.join(@upload_dir, "write_fail.jpg"))
    end
  end
end
