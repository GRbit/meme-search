class ImageTag < ApplicationRecord
  belongs_to :tag_name
  # Tags are part of the API meme object, so a tag change must show up in the updated_at change feed.
  belongs_to :image_core, touch: true
end
