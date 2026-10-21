require "test_helper"

class SimilarMemesQueryTest < ActiveSupport::TestCase
  setup do
    ImageEmbedding.delete_all
    @source = image_cores(:one)
  end

  test "ranks other memes by their closest chunk to the source full-text chunk" do
    embed(@source, "this image says all the fucks", axis_vector(0))
    embed(@source, "says all", axis_vector(1))
    embed(image_cores(:two), "close to the whole description", blend(0, 1, 0.9))
    embed(image_cores(:two), "unrelated chunk", axis_vector(5))
    # Identical to a short source chunk only: an all-pairs minimum would rank it first.
    embed(image_cores(:three), "says all", axis_vector(1))

    results = SimilarMemesQuery.new(image_core: @source, limit: 10).call

    assert_equal [ image_cores(:two), image_cores(:three) ], results
  end

  test "excludes the source meme and returns each neighbour once within the limit" do
    embed(@source, "this image says all the fucks", axis_vector(0))
    embed(@source, "this image says", axis_vector(0))
    3.times { |index| embed(image_cores(:two), "near #{index}", blend(0, 1, 0.99)) }
    embed(image_cores(:three), "farther", blend(0, 1, 0.5))
    embed(image_cores(:four), "farthest", axis_vector(1))

    assert_equal [ image_cores(:two), image_cores(:three), image_cores(:four) ],
      SimilarMemesQuery.new(image_core: @source, limit: 20).call
    assert_equal [ image_cores(:two), image_cores(:three) ],
      SimilarMemesQuery.new(image_core: @source, limit: 2).call
  end

  test "returns nothing when the source meme has no embeddings yet" do
    embed(image_cores(:two), "a neighbour without a source", axis_vector(0))

    assert_empty SimilarMemesQuery.new(image_core: @source, limit: 10).call
  end

  test "clamps the limit to the search bounds" do
    embed(@source, "this image says all the fucks", axis_vector(0))
    embed(image_cores(:two), "near", axis_vector(0))
    embed(image_cores(:three), "far", axis_vector(1))

    assert_equal [ image_cores(:two) ], SimilarMemesQuery.new(image_core: @source, limit: 0).call
  end

  private

    def embed(image_core, snippet, vector)
      ImageEmbedding.create!(image_core: image_core, snippet: snippet, embedding: vector)
    end

    def axis_vector(axis)
      Array.new(384, 0.0).tap { |vector| vector[axis] = 1.0 }
    end

    def blend(axis, other_axis, weight)
      Array.new(384, 0.0).tap do |vector|
        vector[axis] = weight
        vector[other_axis] = 1.0 - weight
      end
    end
end
