# frozen_string_literal: true

require_relative "test_helper"

class ErrorsTest < Minitest::Test
  include Helpers

  def failure(response)
    nohead, = client([response], max_retries: 0)
    assert_raises(Nohead::APIError) { nohead.records.get("rec_1") }
  end

  {
    400 => ["invalid_request", Nohead::InvalidRequestError],
    401 => ["authentication_error", Nohead::AuthenticationError],
    402 => ["plan_limit_exceeded", Nohead::PlanLimitExceededError],
    403 => ["authorization_error", Nohead::AuthorizationError],
    404 => ["not_found", Nohead::NotFoundError],
    409 => ["conflict", Nohead::ConflictError],
    412 => ["precondition_failed", Nohead::PreconditionFailedError],
    422 => ["validation_error", Nohead::ValidationError],
    429 => ["rate_limited", Nohead::RateLimitError],
    500 => ["internal_error", Nohead::InternalServerError],
    503 => ["service_unavailable", Nohead::ServiceUnavailableError]
  }.each do |status, (type, klass)|
    define_method("test_maps_#{type}") do
      error = failure(api_error(status, type, { "x-a" => "b" }))
      assert_instance_of klass, error
      assert_equal "b", error.headers["x-a"]
      assert_equal [status, type, "req_1"], [error.status, error.type, error.request_id]
      assert_equal "#{status} #{type}: #{type} message (request req_1)", error.to_s
    end
  end

  def test_details
    error = failure(api_error(422, "validation_error",
                              details: [{ field: "title", code: "required", message: "Required" }]))
    assert_equal "title", error.details.first.field
    assert_equal "required", error.details.first["code"]
  end

  def test_current_revision
    error = failure(api_error(412, "precondition_failed",
                              details: [{ code: "revision_mismatch", message: "...", current_revision: 7 }]))
    assert_equal 7, error.current_revision
  end

  def test_retry_after
    assert_equal 30, failure(api_error(429, "rate_limited", { "retry-after" => "30" })).retry_after
  end

  def test_bodies_that_are_not_api_errors
    html = Nohead::Response.new(502, { "content-type" => "text/html", "x-request-id" => "req_9" },
                                "<html>Bad gateway</html>")
    error = failure(html)
    assert_instance_of Nohead::InternalServerError, error
    assert_equal "<html>Bad gateway</html>", error.body
    assert_equal "req_9", error.request_id
  end

  def test_fields_of_the_wrong_type
    # A gateway's JSON that looks like an envelope but is not one.
    body = { "error" => { "type" => ["x"], "message" => { "text" => "x" }, "request_id" => 7,
                          "details" => { "code" => "x" } } }
    error = failure(Nohead::Response.new(502, { "content-type" => "application/json", "x-request-id" => "req_9" },
                                         JSON.generate(body)))
    assert_instance_of Nohead::InternalServerError, error
    assert_equal [nil, "req_9", []], [error.type, error.request_id, error.details]
    assert_equal "502 error: Request failed with status 502 (request req_9)", error.to_s
  end

  def test_unknown_types_stay_api_errors
    assert_instance_of Nohead::APIError, failure(api_error(418, "teapot_error"))
  end
end
