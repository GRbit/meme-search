require "test_helper"

class QueueConfigTest < ActiveSupport::TestCase
  test "worker threads default to 3" do
    with_job_threads(nil) { assert_equal 3, worker_threads }
  end

  test "worker threads follow JOB_THREADS" do
    with_job_threads("1") { assert_equal 1, worker_threads }
  end

  private
    def worker_threads
      yaml = ERB.new(Rails.root.join("config/queue.yml").read).result
      YAML.safe_load(yaml, aliases: true).dig("production", "workers", 0, "threads")
    end

    def with_job_threads(value)
      previous = ENV["JOB_THREADS"]
      value.nil? ? ENV.delete("JOB_THREADS") : ENV["JOB_THREADS"] = value
      yield
    ensure
      previous.nil? ? ENV.delete("JOB_THREADS") : ENV["JOB_THREADS"] = previous
    end
end
