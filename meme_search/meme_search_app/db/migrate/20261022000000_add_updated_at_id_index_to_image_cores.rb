class AddUpdatedAtIdIndexToImageCores < ActiveRecord::Migration[8.0]
  def change
    # Serves the api v1 listing's (updated_at, id) keyset pagination.
    add_index :image_cores, [ :updated_at, :id ]
  end
end
