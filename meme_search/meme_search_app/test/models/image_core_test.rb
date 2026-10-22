require "test_helper"

class ImageCoreTest < ActiveSupport::TestCase
  setup do
    @original_model = $embedding_model
    $embedding_model = ->(_text) { Array.new(384, 0.0) }
  end

  teardown do
    $embedding_model = @original_model
  end

  test "recomputing existing embeddings keeps updated_at so the gallery order and change feed stay put" do
    image_core = image_cores(:one)
    assert image_core.image_embeddings.exists?
    original = image_core.updated_at

    travel_to 1.hour.from_now do
      image_core.refresh_description_embeddings
    end

    assert image_core.image_embeddings.exists?
    assert_equal original, image_core.reload.updated_at
  end

  test "first embeddings bump updated_at because the meme becomes ready" do
    image_core = image_cores(:four)
    image_core.image_embeddings.delete_all
    original = image_core.updated_at

    travel_to 1.hour.from_now do
      image_core.refresh_description_embeddings
    end

    assert image_core.image_embeddings.exists?
    assert_operator image_core.reload.updated_at, :>, original
  end

  test "dropping the last embeddings bumps updated_at because the meme stops being ready" do
    image_core = image_cores(:one)
    image_core.update_column(:description, nil)
    original = image_core.reload.updated_at

    travel_to 1.hour.from_now do
      image_core.refresh_description_embeddings
    end

    assert_not image_core.image_embeddings.exists?
    assert_operator image_core.reload.updated_at, :>, original
  end
end
