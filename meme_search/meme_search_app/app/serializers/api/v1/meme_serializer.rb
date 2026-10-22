# frozen_string_literal: true

module Api
  module V1
    class MemeSerializer
      DESCRIPTION_STATUSES = %w[pending ready failed].freeze

      # One query for a whole page of results instead of one EXISTS per meme.
      def self.embedded_image_core_ids(image_cores)
        ImageEmbedding.where(image_core_id: image_cores.map(&:id)).distinct.pluck(:image_core_id).to_set
      end

      def initialize(image_core, content_url:, embedded:)
        @image_core = image_core
        @content_url = content_url
        @embedded = embedded
      end

      def as_json(*)
        {
          id: image_core.id,
          filename: image_core.name,
          description: image_core.description,
          tags: image_core.image_tags.filter_map { |tag| tag.tag_name&.name },
          media_type: Rack::Mime.mime_type(File.extname(image_core.name.to_s).downcase, "application/octet-stream"),
          content_url: content_url,
          folder: image_core.image_path&.name,
          description_status: description_status
        }
      end

      private

        attr_reader :image_core, :content_url, :embedded

        # Derived from stored facts rather than the queue status: a hand-typed description
        # is searchable, and "done" is set before the embeddings exist.
        def description_status
          if image_core.description.present? && embedded
            "ready"
          elsif image_core.failed? && image_core.description.blank?
            "failed"
          else
            "pending"
          end
        end
    end
  end
end
