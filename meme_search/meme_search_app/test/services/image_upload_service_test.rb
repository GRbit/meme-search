require "test_helper"

class ImageUploadServiceTest < ActiveSupport::TestCase
  JPEG = Base64.decode64("/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAv/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFQEBAQAAAAAAAAAAAAAAAAAAAAX/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIRAxEAPwCwAA//2Q==")

  def setup
    @upload_dir = Rails.root.join("public", "memes", "direct-uploads")
    FileUtils.mkdir_p(@upload_dir)
    @existing_upload_files = Dir.glob(File.join(@upload_dir, "*")).select { |file| File.file?(file) }
  end

  def teardown
    Dir.glob(File.join(@upload_dir, "*")).each do |file|
      File.delete(file) if File.file?(file) && !@existing_upload_files.include?(file)
    end
  end

  def upload(filename, content = JPEG)
    Rack::Test::UploadedFile.new(StringIO.new(content), "image/jpeg", original_filename: filename)
  end

  test "defaults to the direct-uploads path and returns the legacy hash" do
    ImagePath.find_by(name: "direct-uploads")&.destroy

    result = ImageUploadService.new.call([ upload("service_ok.jpg") ])

    assert result.success?
    assert_equal ImagePath.find_by!(name: "direct-uploads"), result.image_path
    assert_equal(
      {
        success: [ { success: true, filename: "service_ok.jpg", size: JPEG.bytesize, path: "/memes/direct-uploads/service_ok.jpg" } ],
        errors: [],
        scan: { added: 1, removed: 0, unsafe: 0 }
      },
      result.to_h
    )
  end

  test "omits the scan when nothing was stored" do
    result = ImageUploadService.new.call([ upload("service_bad.jpg", "not an image") ])

    assert_not result.success?
    assert_equal [ :success, :errors ], result.to_h.keys
    assert_equal "Invalid image file. File content does not match image format.", result.errors.first[:error]
  end

  test "stores into and scans the given image path" do
    directory = Rails.root.join("public", "memes", "upload-service-test")
    FileUtils.mkdir_p(directory)
    image_path = ImagePath.create!(name: "upload-service-test")

    result = ImageUploadService.new(image_path: image_path).call([ upload("elsewhere.jpg") ])

    assert result.success?
    assert_equal "/memes/upload-service-test/elsewhere.jpg", result.uploaded.first[:path]
    assert_equal JPEG, File.binread(directory.join("elsewhere.jpg"))
    assert image_path.image_cores.exists?(name: "elsewhere.jpg")
    assert_not File.exist?(@upload_dir.join("elsewhere.jpg"))
  ensure
    image_path&.image_cores&.delete_all
    image_path&.destroy
    FileUtils.rm_rf(directory) if directory
  end
end
