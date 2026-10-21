class AddIncludeSubfoldersToImagePaths < ActiveRecord::Migration[8.0]
  def change
    add_column :image_paths, :include_subfolders, :boolean, default: false, null: false
  end
end
