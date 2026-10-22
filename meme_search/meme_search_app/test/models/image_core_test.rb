require "test_helper"

class ImageCoreTest < ActiveSupport::TestCase
  # The cleaning regex before multilingual support, kept to prove ASCII input is unaffected.
  LEGACY_CLEAN = ->(text) { text.downcase.strip.gsub(/[^a-z0-9,.!?']/, " ").gsub(/\s+/, " ") }

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

  test "refresh_description_embeddings keeps old embeddings when inference fails" do
    $embedding_model = FakeEmbeddingModel.new(fail_on_call: 2)

    assert_raises(RuntimeError) { @image_core.refresh_description_embeddings }

    assert_equal @old_embedding_ids.sort, ImageEmbedding.where(image_core_id: @image_core.id).pluck(:id).sort
  end

  test "refresh_description_embeddings keeps old embeddings when saving a new one fails" do
    # A 385-dim vector fails validation on save!, so the failure happens after inference, inside the swap.
    $embedding_model = FakeEmbeddingModel.new(fail_on_call: 2, failure: -> { Array.new(385, 0.3) })

    assert_raises(ActiveRecord::RecordInvalid) { @image_core.refresh_description_embeddings }

    assert_equal @old_embedding_ids.sort, ImageEmbedding.where(image_core_id: @image_core.id).pluck(:id).sort
  end

  test "recomputing existing embeddings keeps updated_at so the gallery order and change feed stay put" do
    $embedding_model = FakeEmbeddingModel.new
    image_core = image_cores(:one)
    assert image_core.image_embeddings.exists?
    original = image_core.updated_at

    travel_to 1.hour.from_now do
      image_core.refresh_description_embeddings
    end

    assert image_core.image_embeddings.exists?
    assert_equal original, image_core.reload.updated_at
  end

  test "first embeddings bump updated_at because the meme becomes ready" do
    $embedding_model = FakeEmbeddingModel.new
    image_core = image_cores(:four)
    image_core.image_embeddings.delete_all
    original = image_core.updated_at

    travel_to 1.hour.from_now do
      image_core.refresh_description_embeddings
    end

    assert image_core.image_embeddings.exists?
    assert_operator image_core.reload.updated_at, :>, original
  end

  test "dropping the last embeddings bumps updated_at because the meme stops being ready" do
    $embedding_model = FakeEmbeddingModel.new
    image_core = image_cores(:one)
    image_core.update_column(:description, nil)
    original = image_core.reload.updated_at

    travel_to 1.hour.from_now do
      image_core.refresh_description_embeddings
    end

    assert_not image_core.image_embeddings.exists?
    assert_operator image_core.reload.updated_at, :>, original
  end

  test "a description without Latin words produces embeddings" do
    image_core = image_cores(:one)
    image_core.update_column(:description, "Скелет сидит на скамейке и ждёт")

    assert_nothing_raised { image_core.refresh_description_embeddings }

    snippets = ImageEmbedding.where(image_core_id: image_core.id).order(:id).pluck(:snippet)
    assert_equal [
      "скелет сидит на скамейке и ждёт",
      "скелет сидит на скамейке",
      "на скамейке и ждёт",
      "и ждёт"
    ], snippets
    assert ImageEmbedding.where(image_core_id: image_core.id).all? { |embedding| embedding.embedding.length == 384 }
  end

  test "chunk_text keeps Cyrillic words and handles punctuation as before" do
    chunks = ImageCore.new.send(:chunk_text, "Кот сказал: «Нет!» и ушёл, cat said no?")

    assert_equal [
      "кот сказал: «нет!» и ушёл, cat said no?",
      "кот сказал нет! и",
      "нет! и ушёл, cat",
      "ушёл, cat said no?",
      "said no?"
    ], chunks
  end

  test "clean_word keeps letters and digits of other scripts" do
    assert_equal "café 東京 2024 ½", ImageCore.new.send(:clean_word, "Café 東京 2024 ½")
  end

  test "clean_word output for ASCII input is unchanged" do
    every_ascii_char = (0..127).map(&:chr).join
    samples = [
      every_ascii_char,
      "  This image says: DID you just take BOTH pills?! (yes) #meme @user 100% ",
      "don't stop-me_now\tplease\nok."
    ]

    samples.each do |sample|
      assert_equal LEGACY_CLEAN.call(sample), ImageCore.new.send(:clean_word, sample)
    end
  end
end
