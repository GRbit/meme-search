require "test_helper"

class ImageTagTest < ActiveSupport::TestCase
  test "adding and removing a tag bumps the meme updated_at for the api change feed" do
    image_core = image_cores(:four)
    original = image_core.updated_at

    travel_to 1.hour.from_now do
      image_tag = ImageTag.create!(image_core: image_core, tag_name: tag_names(:one))
      assert_operator image_core.reload.updated_at, :>, original

      added_at = image_core.updated_at
      travel 1.minute
      image_tag.destroy!
      assert_operator image_core.reload.updated_at, :>, added_at
    end
  end
end
