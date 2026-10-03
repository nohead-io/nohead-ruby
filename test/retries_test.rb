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

  def test_waits_out_a_short_retry_after
    nohead, transport = client([api_error(429, "rate_limited", NOW), json(200, record("r"))])
    nohead.records.get("r")
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
end
