require "test_helper"

class NestedImagePathUrlsTest < ActionDispatch::IntegrationTest
  PNG = [ "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d49444154789c6360000002000001e221bc330000000049454e44ae426082" ].pack("H*")

  setup do
    @parent = Rails.root.join("public", "memes", "nested-test-#{SecureRandom.hex(6)}")
    @leaf = @parent.join("leaf dir")
    FileUtils.mkdir_p(@leaf)
    @file_name = "мем #1.png"
    File.binwrite(@leaf.join(@file_name), PNG)
    image_path = ImagePath.create!(name: "#{@parent.basename}/leaf dir")
    @image_core = ImageCore.find_by!(image_path: image_path, name: @file_name)
  end

  teardown do
    FileUtils.rm_rf(@parent)
  end

  test "detail page img src for a nested path resolves to the file" do
    get image_core_url(@image_core)
    assert_response :success

    src = css_select("img").map { |img| img["src"] }.find { |s| s.include?("/memes/") }
    assert_not_nil src, "expected an img pointing into /memes/"

    get URI(src).request_uri
    assert_response :success
    assert_equal PNG, response.body.b
  end
end
