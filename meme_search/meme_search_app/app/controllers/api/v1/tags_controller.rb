# frozen_string_literal: true

module Api
  module V1
    class TagsController < BaseController
      rate_limit to: 60, within: 1.minute, by: -> { current_api_token&.id || request.remote_ip },
        store: Rails.application.config.x.api_rate_limit_store,
        with: -> { render_api_error(:rate_limited, "Too many requests. Try again shortly.", :too_many_requests) }

      def index
        return unless require_scope!("search:read")

        # The inner join drops tags no meme carries; DISTINCT guards against a
        # tag attached twice to one meme.
        tags = TagName
          .joins(:image_tags)
          .group("tag_names.id", "tag_names.name")
          .order("tag_names.name")
          .pluck("tag_names.name", Arel.sql("COUNT(DISTINCT image_tags.image_core_id)"))
          .map { |name, count| { name: name, meme_count: count } }

        render json: { data: tags, meta: { count: tags.length } }
      end
    end
  end
end
