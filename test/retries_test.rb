# frozen_string_literal: true

require_relative "test_helper"

class RetriesTest < Minitest::Test
  include Helpers

  # Cases of plain API errors, by status.
  def self.errors(types, pauses)
    types.to_h { |status, type| ["#{status} #{type}", [-> { api_error(status, type) }, pauses]] }
  end

  # What a write's first attempt gets, and the waits before its retries: nil
  # when it is not retried. Backoff is 0.5 s here (no jitter).
  CASES = {
    "409 conflict" => [-> { api_error(409, "conflict", details: [{ code: "taken", message: "Taken" }]) }, nil],
    "409 in progress" => [-> { api_error(409, "conflict", details: [{ code: "in_progress", message: "..." }]) }, [0.5]],
    **errors({ 400 => "invalid_request", 401 => "authentication_error", 402 => "plan_limit_exceeded",
               403 => "authorization_error", 404 => "not_found", 412 => "precondition_failed",
               422 => "validation_error" }, nil),
    **errors({ 429 => "rate_limited", 500 => "internal_error", 502 => "internal_error",
               503 => "service_unavailable", 504 => "internal_error" }, [0.5]),
    "503 with Retry-After" => [-> { api_error(503, "service_unavailable", { "retry-after" => "7" }) }, [7]],
    "429 with Retry-After 60 s" => [-> { api_error(429, "rate_limited", { "retry-after" => "60" }) }, [60]],
    "429 with Retry-After 61 s" => [-> { api_error(429, "rate_limited", { "retry-after" => "61" }) }, nil],
    "429 with an unparseable Retry-After" => [-> { api_error(429, "rate_limited", { "retry-after" => "soon" }) },
                                              [0.5]],
    "429 with Retry-After between spaces" => [-> { api_error(429, "rate_limited", { "retry-after" => " 5 " }) }, [5]],
    "429 with Retry-After 1.5 s" => [-> { api_error(429, "rate_limited", { "retry-after" => "1.5" }) }, [1.5]],
    # Not seconds or an HTTP date: backoff instead.
    **%w[+5 .5 -1 1e3 inf nan 0x10 2026-10-02T12:00:05Z].each_with_index.to_h do |value, index|
      ["429 with unreadable Retry-After #{index}",
       [-> { api_error(429, "rate_limited", { "retry-after" => value }) }, [0.5]]]
    end,
    "connection error" => [-> { Nohead::ConnectionError.new("refused") }, [0.5]],
    "timeout" => [-> { Nohead::TimeoutError.new("slow") }, [0.5]]
  }.freeze

  CASES.each do |name, (first, pauses)|
    define_method("test_after_a_#{name.downcase.gsub(/\W+/, '_')}") do
      nohead, transport = client([instance_exec(&first), json(201, record("r"))])
      nohead.define_singleton_method(:rand) { 0.0 }
      if pauses
        assert_equal "r", nohead.records.create("posts", data: {}).id
      else
        assert_raises(Nohead::APIError) { nohead.records.create("posts", data: {}) }
      end
      assert_equal pauses.to_a, nohead.pauses
      assert_equal pauses ? 2 : 1, transport.requests.size
      # A retry is the same write: it keeps the Idempotency-Key.
      assert_equal 1, transport.requests.map { |request| request.headers["Idempotency-Key"] }.uniq.size
    end
  end

  def test_gives_up_after_the_default_two_retries
    nohead, transport = client([api_error(500, "internal_error")])
    assert_raises(Nohead::InternalServerError) { nohead.records.get("r") }
    assert_equal 3, transport.requests.size
  end

  def test_backs_off_exponentially_with_jitter_up_to_8_s
    nohead, = client([api_error(500, "internal_error")], max_retries: 6)
    nohead.define_singleton_method(:rand) { 0.5 } # 12.5% off each delay
    assert_raises(Nohead::InternalServerError) { nohead.records.get("r") }
    assert_equal [0.4375, 0.875, 1.75, 3.5, 7.0, 7.0], nohead.pauses
  end

  def test_reads_a_retry_after_date_in_each_http_format
    ["Fri, 02 Oct 2026 12:00:05 GMT", "Friday, 02-Oct-26 12:00:05 GMT", "Fri Oct  2 12:00:05 2026"].each do |date|
      nohead, = client([api_error(429, "rate_limited", { "retry-after" => date }), json(200, record("r"))])
      at_time(Time.utc(2026, 10, 2, 12)) { nohead.records.get("r") }
      assert_equal [5], nohead.pauses, date
    end
  end

  def test_stops_after_max_retries
    nohead, transport = client([Nohead::TimeoutError.new("slow")], max_retries: 0)
    assert_raises(Nohead::TimeoutError) { nohead.records.get("r") }
    assert_equal 1, transport.requests.size
  end

  def test_retries_a_timeout_sending_the_timeout_each_time
    nohead, transport = client([Nohead::TimeoutError.new("slow"), json(200, record("r"))], timeout: 7)
    assert_equal "r", nohead.records.get("r").id
    assert_equal [7, 7], transport.requests.map(&:timeout)
  end
end
