# frozen_string_literal: true

# Validates uploaded image files, stores them in an ImagePath's directory and
# scans that path so ImageCore records exist for the stored files.
#
# One validated path for every caller: the web upload controller today, any
# other upload entry point later. Callers own the transport (params, status
# codes); per-file outcomes come back as hashes in the web upload JSON shape.
class ImageUploadService
  MAX_FILE_SIZE = 10.megabytes
  ALLOWED_EXTENSIONS = %w[.jpg .jpeg .png .webp .gif].freeze

  # Outcome of one call. `scan` is only part of #to_h when a scan was attempted,
  # which happens only if at least one file was stored. `outcomes` holds the
  # same per-file hashes in input order: a stored file's hash carries the stored
  # name only, so callers that need to pair results with inputs use it.
  class Result
    attr_reader :image_path, :uploaded, :errors, :outcomes, :scan

    def initialize(image_path:, uploaded:, errors:, outcomes:, scanned:, scan:)
      @image_path = image_path
      @uploaded = uploaded
      @errors = errors
      @outcomes = outcomes
      @scanned = scanned
      @scan = scan
    end

    def success?
      errors.empty?
    end

    def scanned?
      @scanned
    end

    def to_h
      hash = { success: uploaded, errors: errors }
      hash[:scan] = scan if scanned?
      hash
    end
  end

  # image_path defaults to the direct-uploads path, created on first use.
  def initialize(image_path: nil)
    @image_path = image_path
  end

  def call(files)
    image_path = @image_path || ImagePath.ensure_direct_uploads_path!
    uploaded = []
    errors = []
    outcomes = []

    files.each do |file|
      result = process_upload(file, image_path)
      outcomes << result

      if result[:success]
        uploaded << result
      else
        errors << result
      end
    end

    scan = image_path.scan_and_update! if uploaded.any?

    Result.new(
      image_path: image_path, uploaded: uploaded, errors: errors, outcomes: outcomes,
      scanned: uploaded.any?, scan: scan
    )
  end

  private

    def process_upload(file, image_path)
      if file.size > MAX_FILE_SIZE
        return {
          success: false,
          filename: file.original_filename,
          error: "File size exceeds maximum allowed (10MB)"
        }
      end

      # Checked on the raw name, before sanitizing: "x.jpg " is rejected.
      extension = File.extname(file.original_filename).downcase
      unless ALLOWED_EXTENSIONS.include?(extension)
        return {
          success: false,
          filename: file.original_filename,
          error: "Invalid file type. Allowed: #{ALLOWED_EXTENSIONS.join(", ")}"
        }
      end

      # The extension and the client's Content-Type are both caller-controlled.
      begin
        mime_type = Marcel::MimeType.for(file.tempfile)
        unless mime_type&.start_with?("image/")
          return {
            success: false,
            filename: file.original_filename,
            error: "Invalid image file. File content does not match image format."
          }
        end
      rescue => e
        return {
          success: false,
          filename: file.original_filename,
          error: "Failed to validate file type: #{e.message}"
        }
      end

      sanitized_filename = sanitize_filename(file.original_filename)
      upload_dir = image_path.directory_path.to_s
      unique_filename = generate_unique_filename(upload_dir, sanitized_filename)
      file_path = File.join(upload_dir, unique_filename)

      begin
        File.open(file_path, "wb") do |f|
          f.write(file.read)
        end

        {
          success: true,
          filename: unique_filename,
          size: file.size,
          path: "/memes/#{image_path.name}/#{unique_filename}"
        }
      rescue Errno::ENOSPC
        {
          success: false,
          filename: file.original_filename,
          error: "Server disk is full. Please free up space or contact administrator."
        }
      rescue Errno::EACCES
        {
          success: false,
          filename: file.original_filename,
          error: "Cannot write to uploads directory. Check Docker volume mount permissions in docker-compose.yml"
        }
      rescue => e
        {
          success: false,
          filename: file.original_filename,
          error: "Failed to save file: #{e.message}"
        }
      end
    end

    # Keeps unicode; strips only path separators, null bytes and control characters.
    def sanitize_filename(filename)
      basename = File.basename(filename)
      sanitized = basename.tr("/", "_").tr("\0", "").gsub(/[\x00-\x1f\x7f]/, "")
      sanitized.gsub(/\s+/, " ").strip
    end

    # Never overwrites an existing file: a clash gets a unix timestamp suffix.
    def generate_unique_filename(upload_dir, filename)
      file_path = File.join(upload_dir, filename)

      return filename unless File.exist?(file_path)

      extension = File.extname(filename)
      basename = File.basename(filename, extension)
      timestamp = Time.now.to_i

      "#{basename}_#{timestamp}#{extension}"
    end
end
