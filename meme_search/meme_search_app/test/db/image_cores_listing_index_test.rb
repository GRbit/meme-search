require "test_helper"

class ImageCoresListingIndexTest < ActiveSupport::TestCase
  test "image cores have the keyset index the api listing pages through" do
    index = ActiveRecord::Base.connection.indexes(:image_cores).find { |candidate| candidate.columns == %w[updated_at id] }

    assert index, "expected an (updated_at, id) index on image_cores"
  end
end
