require "test_helper"

class ImageCoreTest < ActiveSupport::TestCase
  # Stands in for the Informers pipeline so tests need no model download; can fail on a chosen call.
  class FakeEmbeddingModel
    attr_reader :calls

    def initialize(fail_on_call: nil, failure: -> { raise "embedding model failed" })
      @fail_on_call = fail_on_call
      @failure = failure
      @calls = []
    end

    def call(snippet)
      @calls << snippet
      return @failure.call if @calls.length == @fail_on_call

      Array.new(384, 0.3)
    end
  end

  setup do
    @image_core = image_cores(:one)
    @old_embedding_ids = @image_core.image_embeddings.pluck(:id)
    assert_not_empty @old_embedding_ids
    @original_model = $embedding_model
  end

  teardown do
    $embedding_model = @original_model
  end

  test "refresh_description_embeddings replaces old embeddings with one per description chunk" do
    $embedding_model = FakeEmbeddingModel.new

    @image_core.refresh_description_embeddings

    expected_snippets = [
      "this image says all the fucks",
      "this image says all",
      "says all the fucks",
      "the fucks"
    ]
    embeddings = ImageEmbedding.where(image_core_id: @image_core.id).order(:id)
    assert_equal expected_snippets, embeddings.map(&:snippet)
    assert_equal expected_snippets, $embedding_model.calls
    assert_empty ImageEmbedding.where(id: @old_embedding_ids)
  end

  test "refresh_description_embeddings removes embeddings for a nil or empty description" do
    $embedding_model = FakeEmbeddingModel.new

    [ nil, "" ].each do |description|
      ImageEmbedding.create!(image_core: @image_core, snippet: "old", embedding: Array.new(384, 0.1))
      @image_core.description = description

      @image_core.refresh_description_embeddings

      assert_empty ImageEmbedding.where(image_core_id: @image_core.id)
    end
    assert_empty $embedding_model.calls
  end
end
