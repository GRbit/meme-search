# frozen_string_literal: true

module Api
  module V1
    class SearchController < BaseController
      QUERY_MAX_LENGTH = 200
      TAG_MAX_LENGTH = 20
      TAG_MAX_COUNT = 10
      FOLDER_MAX_LENGTH = 300
      FOLDER_MAX_COUNT = 10
      MAX_OFFSET = 200
      ALLOWED_MODES = %w[keyword vector].freeze

      rate_limit to: 60, within: 1.minute, by: -> { current_api_token&.id || request.remote_ip },
        store: Rails.application.config.x.api_rate_limit_store,
        with: -> { render_api_error(:rate_limited, "Too many search requests. Try again shortly.", :too_many_requests) }

      def index
        return unless require_scope!("search:read")
        return unless validate_search_params

        page = ImageSearchQuery.new(
          query: params[:q],
          mode: mode,
          selected_tag_names: requested_tags,
          selected_path_names: requested_folders,
          limit: limit,
          tag_match: tag_match,
          offset: offset
        ).page
        results = page.results
        preload_associations(results)
        embedded_ids = MemeSerializer.embedded_image_core_ids(results)

        render json: {
          data: results.map { |image_core| serialize(image_core, embedded_ids) },
          meta: {
            query: params[:q],
            mode: mode,
            tags: requested_tags,
            folders: requested_folders,
            tag_match: tag_match,
            limit: limit,
            offset: offset,
            count: results.length
          }.merge(next_offset_meta(page))
        }
      end

      def similar
        return unless require_scope!("search:read")
        return unless validate_limit

        image_core = ImageCore.find(params[:id])
        results = SimilarMemesQuery.new(image_core: image_core, limit: limit).call
        preload_associations(results)
        embedded_ids = MemeSerializer.embedded_image_core_ids(results)

        render json: {
          data: results.map { |result| serialize(result, embedded_ids) },
          meta: {
            meme_id: image_core.id,
            limit: limit,
            count: results.length
          }
        }
      end

      private

        def validate_search_params
          if !params[:q].is_a?(String) || params[:q].blank?
            render_api_error(:invalid_query, "q is required.", :unprocessable_entity)
            return false
          end

          if params[:q].to_s.length > QUERY_MAX_LENGTH
            render_api_error(:invalid_query, "q must be at most #{QUERY_MAX_LENGTH} characters.", :unprocessable_entity)
            return false
          end

          if requested_tags.length > TAG_MAX_COUNT || requested_tags.any? { |tag| tag.length > TAG_MAX_LENGTH }
            render_api_error(
              :invalid_tags,
              "Use at most #{TAG_MAX_COUNT} tags of #{TAG_MAX_LENGTH} characters or fewer.",
              :unprocessable_entity
            )
            return false
          end

          return false unless validate_folders

          return false unless validate_limit

          if params[:offset].present? &&
              (parsed_offset.nil? || !parsed_offset.between?(0, MAX_OFFSET))
            render_api_error(
              :invalid_offset,
              "offset must be an integer between 0 and #{MAX_OFFSET}.",
              :unprocessable_entity
            )
            return false
          end

          unless ALLOWED_MODES.include?(mode)
            render_api_error(:invalid_mode, "mode must be keyword or vector.", :unprocessable_entity)
            return false
          end

          return true if ImageSearchQuery::TAG_MATCH_MODES.include?(tag_match)

          render_api_error(:invalid_tag_match, "tag_match must be any or all.", :unprocessable_entity)
          false
        end

        # Unknown folders are rejected rather than matching nothing, so a typo is not
        # mistaken for an empty folder.
        def validate_folders
          if requested_folders.length > FOLDER_MAX_COUNT || requested_folders.any? { |folder| folder.length > FOLDER_MAX_LENGTH }
            render_api_error(
              :invalid_folder,
              "Use at most #{FOLDER_MAX_COUNT} folders of #{FOLDER_MAX_LENGTH} characters or fewer.",
              :unprocessable_entity
            )
            return false
          end

          return true if requested_folders.empty?
          return true if ImagePath.where(name: requested_folders).count == requested_folders.length

          render_api_error(
            :invalid_folder,
            "Every folder must be the exact name of a library folder.",
            :unprocessable_entity
          )
          false
        end

        def tag_match
          params[:tag_match].presence || "any"
        end

        def validate_limit
          return true if params[:limit].blank? ||
            parsed_limit&.between?(1, ImageSearchQuery::MAX_RESULT_LIMIT)

          render_api_error(
            :invalid_limit,
            "limit must be an integer between 1 and #{ImageSearchQuery::MAX_RESULT_LIMIT}.",
            :unprocessable_entity
          )
          false
        end

        def mode
          params[:mode].presence || "keyword"
        end

        def limit
          (parsed_limit || ImageSearchQuery::DEFAULT_RESULT_LIMIT)
            .clamp(1, ImageSearchQuery::MAX_RESULT_LIMIT)
        end

        def parsed_limit
          @parsed_limit ||= Integer(params[:limit].presence || ImageSearchQuery::DEFAULT_RESULT_LIMIT, exception: false)
        end

        def offset
          parsed_offset || 0
        end

        def parsed_offset
          return @parsed_offset if defined?(@parsed_offset)

          @parsed_offset = Integer(params[:offset].presence || 0, exception: false)
        end

        # A next_offset past MAX_OFFSET would be rejected on the follow-up request, so omit it
        def next_offset_meta(page)
          next_offset = offset + limit
          return {} unless page.more && next_offset <= MAX_OFFSET

          { next_offset: next_offset }
        end

        def requested_tags
          @requested_tags ||= query_tag_values
            .map { |value| value.to_s.strip }
            .reject(&:blank?)
            .uniq
        end

        def query_tag_values
          query_values(%w[tag tag[] tags tags[]])
        rescue ArgumentError
          Array(params[:tag]) + Array(params[:tags])
        end

        def requested_folders
          @requested_folders ||= query_folder_values
            .map { |value| value.to_s.strip }
            .reject(&:blank?)
            .uniq
        end

        def query_folder_values
          query_values(%w[folder])
        rescue ArgumentError
          Array(params[:folder])
        end

        # Read repeated values from the raw query string: Rails keeps only the last
        # value of a repeated key without brackets.
        def query_values(names)
          URI.decode_www_form(request.query_string)
            .select { |name, _value| names.include?(name) }
            .map(&:last)
        end

        def preload_associations(results)
          ActiveRecord::Associations::Preloader.new(
            records: results.to_a,
            associations: [ :image_path, { image_tags: :tag_name } ]
          ).call
        end

        def serialize(image_core, embedded_ids)
          MemeSerializer.new(
            image_core,
            content_url: content_api_v1_meme_path(image_core),
            embedded: embedded_ids.include?(image_core.id)
          ).as_json
        end
    end
  end
end
