# frozen_string_literal: true

module Api
  module V2
    # Upload API: stores files through ImageUploadService, the same validated
    # path as the web upload page, and reports one outcome per file.
    class MemesController < BaseController
      MAX_FILES = 10
      RATE_LIMIT = 30
      BOOLEANS = { "true" => true, "false" => false }.freeze
      STORAGE_FAILED_MESSAGE = "The file could not be stored."

      # The service reports outcomes as web UI messages; clients get stable codes.
      # Anything else is a server-side failure whose message may name filesystem paths.
      CLIENT_ERROR_CODES = {
        "File size exceeds maximum allowed" => "file_too_large",
        "Invalid file type." => "unsupported_file_type",
        "Invalid image file." => "invalid_image"
      }.freeze

      # Counted per controller, so uploads and searches never share a budget.
      rate_limit to: RATE_LIMIT, within: 1.minute, by: -> { current_api_token&.id || request.remote_ip },
        store: Rails.application.config.x.api_rate_limit_store,
        with: -> { render_api_error(:rate_limited, "Too many upload requests. Try again shortly.", :too_many_requests) }

      def create
        return unless require_scope!("media:write")
        return unless validate_create_params

        image_path = @folder || ImagePath.ensure_direct_uploads_path!
        entries = classify(uploaded_files, image_path)
        store(entries, image_path)
        queue_descriptions(entries) if generate_description?
        entries.each { |entry| audit(entry, image_path) }

        render json: {
          data: {
            created: entries.select { |entry| entry[:kind] == :created }.map { |entry| created_json(entry) },
            duplicates: entries.select { |entry| entry[:kind] == :duplicate }.map { |entry| duplicate_json(entry) },
            errors: entries.select { |entry| entry[:kind] == :error }.map { |entry| error_json(entry) }
          },
          meta: { folder: image_path.name, generate_description: generate_description? }
        }
      end

      private

        def validate_create_params
          files = uploaded_files
          unless files&.length&.between?(1, MAX_FILES)
            render_api_error(:invalid_files, "files must contain 1 to #{MAX_FILES} uploaded files.", :unprocessable_entity)
            return false
          end

          if params.key?(:folder)
            @folder = find_folder(params[:folder])
            unless @folder
              render_api_error(
                :invalid_folder,
                "folder must be the exact name of an existing library folder.",
                :unprocessable_entity
              )
              return false
            end
          end

          return true if !params.key?(:generate_description) || BOOLEANS.key?(params[:generate_description])

          render_api_error(:invalid_generate_description, "generate_description must be true or false.", :unprocessable_entity)
          false
        end

        # nil unless every element is a real multipart file.
        def uploaded_files
          value = params[:files]
          files = value.is_a?(Array) ? value : [ value ].compact
          files if files.all?(ActionDispatch::Http::UploadedFile)
        end

        def find_folder(name)
          return unless name.is_a?(String)

          image_path = ImagePath.find_by(name: name)
          image_path if image_path&.directory_path&.directory?
        end

        def generate_description?
          BOOLEANS.fetch(params[:generate_description], false)
        end

        # Splits the request into duplicates of files already in the folder,
        # repeats of an earlier file in this request, and files to store.
        def classify(files, image_path)
          finder = FolderDuplicateFinder.new(image_path)
          first_index_by_digest = {}

          files.each_with_index.map do |file, index|
            # Files the service will reject skip the check, so a rejection always
            # wins over "duplicate" and an oversized file is never read here.
            next { file: file, kind: :pending } unless dedupe_candidate?(file)

            digest = FolderDuplicateFinder.digest(file)
            if (existing_name = finder.existing_name(digest, file.size))
              { file: file, kind: :duplicate, image_core: image_path.image_cores.find_by(name: existing_name) }
            elsif first_index_by_digest.key?(digest)
              { file: file, kind: :repeat, first_index: first_index_by_digest[digest] }
            else
              first_index_by_digest[digest] = index
              { file: file, kind: :pending }
            end
          end
        end

        def dedupe_candidate?(file)
          file.size <= ImageUploadService::MAX_FILE_SIZE &&
            ImageUploadService::ALLOWED_EXTENSIONS.include?(File.extname(file.original_filename).downcase)
        end

        def store(entries, image_path)
          pending = entries.select { |entry| entry[:kind] == :pending }
          if pending.any?
            result = ImageUploadService.new(image_path: image_path).call(pending.map { |entry| entry[:file] })
            pending.zip(result.outcomes).each do |entry, outcome|
              if outcome[:success]
                entry[:kind] = :created
                # scan_and_update! skips a folder that is already being scanned, so the
                # record may not exist yet; create it the way the scan would.
                entry[:image_core] = ImageCore.find_or_create_by!(image_path: image_path, name: outcome[:filename])
              else
                entry[:kind] = :error
                entry[:code], entry[:message] = client_error(outcome[:error])
              end
            end
          end

          entries.each do |entry|
            next unless entry[:kind] == :repeat

            first = entries[entry[:first_index]]
            entry[:kind] = :duplicate
            entry[:image_core] = first[:image_core] if first[:kind] == :created
          end
        end

        def client_error(message)
          CLIENT_ERROR_CODES.each do |prefix, code|
            return [ code, message ] if message.start_with?(prefix)
          end

          Rails.logger.warn("[API v2 ingest] storage failure: #{message}")
          [ "storage_failed", STORAGE_FAILED_MESSAGE ]
        end

        # Mirrors ImageCoresController#generate_description; embeddings follow
        # once the description arrives.
        def queue_descriptions(entries)
          configuration = ImageDescriptionProviders::Configuration.current
          provider = ImageDescriptionProviders::Factory.build(configuration)

          entries.each do |entry|
            next unless entry[:kind] == :created

            entry[:description_queued] = queue_description(entry[:image_core], provider, configuration)
          end
        end

        def queue_description(image_core, provider, configuration)
          return provider.generate(image_core).success? if provider.queued_provider?

          attempt = image_core.start_description_generation_attempt!(
            provider: provider.name,
            provider_settings: configuration.job_options
          )
          image_core.update!(status: :in_queue)
          GenerateImageDescriptionJob.perform_later(image_core.id, configuration.job_options, attempt.id)
          true
        rescue ActiveRecord::RecordInvalid => e
          Rails.logger.warn("[API v2 ingest] description not queued for meme #{image_core.id}: #{e.message}")
          false
        end

        # Names are inspected so a crafted file name cannot forge extra log lines.
        def audit(entry, image_path)
          file = entry[:file]
          result = entry[:kind] == :error ? entry[:code] : entry[:kind]
          line = "[API v2 ingest] token=#{current_api_token.token_prefix} folder=#{image_path.name.inspect} " \
            "file=#{file.original_filename.inspect} size=#{file.size} result=#{result}"
          line += " meme_id=#{entry[:image_core].id}" if entry[:image_core]
          Rails.logger.info(line)
        end

        def created_json(entry)
          {
            filename: entry[:file].original_filename,
            description_queued: entry.fetch(:description_queued, false),
            meme: meme_json(entry[:image_core])
          }
        end

        def duplicate_json(entry)
          { filename: entry[:file].original_filename, meme: entry[:image_core] && meme_json(entry[:image_core]) }
        end

        def error_json(entry)
          { filename: entry[:file].original_filename, error: { code: entry[:code], message: entry[:message] } }
        end

        def meme_json(image_core)
          Api::V1::MemeSerializer.new(image_core, content_url: content_api_v1_meme_path(image_core)).as_json
        end
    end
  end
end
