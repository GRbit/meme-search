# frozen_string_literal: true

module Api
  module V1
    class FoldersController < BaseController
      rate_limit to: 60, within: 1.minute, by: -> { current_api_token&.id || request.remote_ip },
        store: Rails.application.config.x.api_rate_limit_store,
        with: -> { render_api_error(:rate_limited, "Too many requests. Try again shortly.", :too_many_requests) }

      def index
        return unless require_scope!("search:read")

        # Unlike tags, empty folders are listed: search accepts every registered
        # folder, and a new or not yet scanned folder is still a valid target.
        folders = ImagePath
          .left_joins(:image_cores)
          .group("image_paths.id", "image_paths.name")
          .order("image_paths.name")
          .pluck("image_paths.name", Arel.sql("COUNT(image_cores.id)"))
          .map { |name, count| { name: name, meme_count: count } }

        render json: { data: folders, meta: { count: folders.length } }
      end
    end
  end
end
