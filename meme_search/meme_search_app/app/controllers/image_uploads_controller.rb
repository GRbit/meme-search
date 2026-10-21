class ImageUploadsController < ApplicationController
  MAX_FILE_SIZE = ImageUploadService::MAX_FILE_SIZE
  ALLOWED_EXTENSIONS = ImageUploadService::ALLOWED_EXTENSIONS

  def new
    # Render the upload form
  end

  def create
    uploaded_files = params[:files]

    # Checked before the service runs so an empty request never creates the direct-uploads path.
    if uploaded_files.blank?
      render json: { error: "No files selected" }, status: :unprocessable_entity
      return
    end

    result = ImageUploadService.new.call(uploaded_files)

    render json: result.to_h, status: result.success? ? :ok : :unprocessable_entity
  end
end
