# frozen_string_literal: true

module Api
  module V1
    class MemesController < BaseController
      LIST_DEFAULT_LIMIT = 50
      LIST_MAX_LIMIT = 100
      CURSOR_MAX_LENGTH = 200

      class InvalidCursor < StandardError; end

      # Its own bucket so a full sync does not starve the same token's searches.
      rate_limit to: 60, within: 1.minute, only: :index,
        by: -> { current_api_token&.id || request.remote_ip },
        store: Rails.application.config.x.api_rate_limit_store,
        with: -> { render_api_error(:rate_limited, "Too many listing requests. Try again shortly.", :too_many_requests) }

      before_action -> { require_scope!("search:read") }, only: [ :index, :show ]
      before_action -> { require_scope!("media:read") }, only: :content
      before_action :set_image_core, except: :index

      def index
        return unless validate_list_params

        relation = ImageCore.order(:updated_at, :id).includes(image_tags: :tag_name)
        if cursor_position
          relation = relation.where("(image_cores.updated_at, image_cores.id) > (?, ?)", *cursor_position)
        end
        # One extra row tells whether another page exists without a COUNT.
        records = relation.limit(list_limit + 1).to_a
        has_more = records.length > list_limit
        records = records.first(list_limit)
        embedded_ids = MemeSerializer.embedded_image_core_ids(records)

        render json: {
          data: records.map do |image_core|
            MemeSerializer.new(
              image_core,
              content_url: content_api_v1_meme_path(image_core),
              embedded: embedded_ids.include?(image_core.id)
            ).as_json
          end,
          meta: {
            limit: list_limit,
            count: records.length,
            has_more: has_more,
            next_cursor: records.last && encode_cursor(records.last)
          }.compact
        }
      end

      def show
        render json: {
          data: MemeSerializer.new(
            @image_core,
            content_url: content_api_v1_meme_path(@image_core),
            embedded: @image_core.image_embeddings.exists?
          ).as_json
        }
      end

      def content
        path = @image_core.safe_source_file_path

        response.headers["Cache-Control"] = "private, max-age=300"
        response.headers["X-Content-Type-Options"] = "nosniff"
        send_file(
          path,
          filename: @image_core.name,
          type: Marcel::MimeType.for(path, name: @image_core.name) || "application/octet-stream",
          disposition: :inline
        )
      rescue ImageCore::FileDeletionError, ImageCore::UnsafeSourceFileError, ActionController::MissingFile
        render_not_found
      end

      private

        def validate_list_params
          if params[:limit].present? && (parsed_list_limit.nil? || !parsed_list_limit.between?(1, LIST_MAX_LIMIT))
            render_api_error(
              :invalid_limit,
              "limit must be an integer between 1 and #{LIST_MAX_LIMIT}.",
              :unprocessable_entity
            )
            return false
          end

          cursor_position
          true
        rescue InvalidCursor
          render_api_error(:invalid_cursor, "cursor must be a value returned in meta.next_cursor.", :unprocessable_entity)
          false
        end

        def list_limit
          parsed_list_limit || LIST_DEFAULT_LIMIT
        end

        def parsed_list_limit
          return @parsed_list_limit if defined?(@parsed_list_limit)

          @parsed_list_limit = params[:limit].present? ? Integer(params[:limit].to_s, 10, exception: false) : nil
        end

        # The cursor is opaque to clients; microseconds keep it exact against timestamp(6) columns,
        # and the id breaks ties between memes saved in the same instant.
        def encode_cursor(image_core)
          Base64.urlsafe_encode64(JSON.generate([ image_core.updated_at.utc.iso8601(6), image_core.id ]), padding: false)
        end

        def cursor_position
          return @cursor_position if defined?(@cursor_position)
          return @cursor_position = nil unless params.key?(:cursor)

          raw = params[:cursor]
          raise InvalidCursor unless raw.is_a?(String) && raw.length.between?(1, CURSOR_MAX_LENGTH)

          decoded = JSON.parse(Base64.urlsafe_decode64(raw))
          raise InvalidCursor unless decoded.is_a?(Array) && decoded.length == 2

          timestamp, id = decoded
          raise InvalidCursor unless timestamp.is_a?(String) && id.is_a?(Integer) && id.positive?

          @cursor_position = [ Time.iso8601(timestamp), id ]
        rescue ArgumentError, JSON::ParserError
          raise InvalidCursor
        end

        def set_image_core
          @image_core = ImageCore.find(params[:id])
        end
    end
  end
end
