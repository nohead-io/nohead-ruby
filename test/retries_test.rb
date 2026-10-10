# frozen_string_literal: true

require_relative "test_helper"

class RetriesTest < Minitest::Test
  include Helpers

  NOW = { "retry-after" => "0" }.freeze

  def test_retries_server_errors_with_one_idempotency_key
    nohead, transport = client([api_error(500, "internal_error", NOW),
                                api_error(503, "service_unavailable", NOW), json(201, record("r"))])
    assert_equal "r", nohead.records.create("posts", data: {}).id
    assert_equal 3, transport.requests.size
    assert_equal 1, transport.requests.map { |request| request.headers["Idempotency-Key"] }.uniq.size
  end

  [502, 504].each do |status|
    define_method("test_retries_#{status}") do
      nohead, transport = client([api_error(status, "internal_error"), json(200, record("r"))])
      nohead.records.get("r")
      assert_equal 2, transport.requests.size
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

  def test_waits_out_a_short_retry_after
    nohead, transport = client([api_error(429, "rate_limited", { "retry-after" => "3" }), json(200, record("r"))])
    nohead.records.get("r")
    assert_equal [3], nohead.pauses
    assert_equal 2, transport.requests.size
  end

  def test_reads_a_retry_after_date
    nohead, = client([api_error(429, "rate_limited", { "retry-after" => "Fri, 02 Oct 2026 12:00:05 GMT" }),
                      json(200, record("r"))])
    at_time(Time.utc(2026, 10, 2, 12)) { nohead.records.get("r") }
    assert_equal [5], nohead.pauses
  end

  def test_backs_off_on_a_429_without_retry_after
    nohead, transport = client([api_error(429, "rate_limited"), json(200, record("r"))])
    nohead.define_singleton_method(:rand) { 0.0 }
    nohead.records.get("r")
    assert_equal [0.5], nohead.pauses
    assert_equal 2, transport.requests.size
  end

  def test_gives_up_on_a_long_retry_after
    nohead, transport = client([api_error(429, "rate_limited", { "retry-after" => "120" })])
    assert_raises(Nohead::RateLimitError) { nohead.records.get("r") }
    assert_equal 1, transport.requests.size
  end

  def test_retries_a_request_in_progress
    busy = api_error(409, "conflict", NOW, details: [{ code: "in_progress", message: "..." }])
    nohead, transport = client([busy, json(201, record("r"))])
    nohead.records.create("posts", data: {})
    assert_equal 2, transport.requests.size
  end

  def test_does_not_retry_other_client_errors
    nohead, transport = client([api_error(422, "validation_error")])
    assert_raises(Nohead::ValidationError) { nohead.records.create("posts", data: {}) }
    assert_equal 1, transport.requests.size
  end

  def test_retries_connection_failures
    nohead, transport = client([Nohead::ConnectionError.new("refused"), json(200, record("r"))])
    nohead.records.get("r")
    assert_equal 2, transport.requests.size
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
