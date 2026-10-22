require "test_helper"

class ImageCoresHelperTest < ActionView::TestCase
  def build_core(path_name, file_name)
    ImageCore.new(image_path: ImagePath.new(name: path_name), name: file_name)
  end

  test "single segment path keeps the plain ASCII url" do
    path, name = absolute_image_path(build_core("example_memes_1", "cat.jpg"))

    assert_equal "http://test.host/memes/example_memes_1/cat.jpg", path
    assert_equal "cat.jpg", name
  end

  test "url has no double slash after the host" do
    path, = absolute_image_path(build_core("example_memes_1", "cat.jpg"))

    assert_no_match %r{\Ahttps?://[^/]+//}, path
  end

  test "nested path keeps every segment" do
    path, = absolute_image_path(build_core("telegram/grbit", "x.jpg"))

    assert_equal "http://test.host/memes/telegram/grbit/x.jpg", path
  end

  test "file name with space, hash, question mark, percent and Cyrillic is escaped" do
    path, name = absolute_image_path(build_core("telegram/grbit", "мем #1 50%? a.jpg"))

    assert_equal "http://test.host/memes/telegram/grbit/%D0%BC%D0%B5%D0%BC%20%231%2050%25%3F%20a.jpg", path
    assert_equal "мем #1 50%? a.jpg", name
  end

  test "path segments are escaped but separators are kept" do
    path, = absolute_image_path(build_core("my memes/папка #2", "a.jpg"))

    assert_equal "http://test.host/memes/my%20memes/%D0%BF%D0%B0%D0%BF%D0%BA%D0%B0%20%232/a.jpg", path
  end
end
