# frozen_string_literal: true

require_relative "test_helper"

class ErrorsTest < Minitest::Test
  include Helpers

  def failure(response)
    nohead, = client([response], max_retries: 0)
    assert_raises(Nohead::APIError) { nohead.records.get("rec_1") }
  end

  # The class and a status of each error type.
  CLASSES = {
    "invalid_request" => [Nohead::InvalidRequestError, 400],
    "authentication_error" => [Nohead::AuthenticationError, 401],
    "plan_limit_exceeded" => [Nohead::PlanLimitExceededError, 402],
    "authorization_error" => [Nohead::AuthorizationError, 403],
    "not_found" => [Nohead::NotFoundError, 404],
    "conflict" => [Nohead::ConflictError, 409],
    "precondition_failed" => [Nohead::PreconditionFailedError, 412],
    "validation_error" => [Nohead::ValidationError, 422],
    "rate_limited" => [Nohead::RateLimitError, 429],
    "internal_error" => [Nohead::InternalServerError, 500],
    "service_unavailable" => [Nohead::ServiceUnavailableError, 503]
  }.freeze

  TYPES = Spec::CONTRACT.dig("components", "schemas", "ErrorType", "enum")

  # Every type the contract has, so a new one fails until it has a class.
  TYPES.each do |type|
    define_method("test_maps_#{type}") do
      klass, status = CLASSES.fetch(type) { flunk "#{type} has no error class" }
      error = failure(api_error(status, type, { "x-a" => "b" }))
      assert_instance_of klass, error
      assert_equal "b", error.headers["x-a"]
      assert_equal [status, type, "req_1"], [error.status, error.type, error.request_id]
      assert_equal "#{status} #{type}: #{type} message (request req_1)", error.to_s
    end
  end

  def test_the_sdk_knows_the_contracts_types
    assert_equal TYPES.sort, Nohead::ERROR_CLASSES.keys.sort
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
    error = failure(raw(html))
    assert_instance_of Nohead::InternalServerError, error
    assert_equal "<html>Bad gateway</html>", error.body
    assert_equal "req_9", error.request_id
  end

  def test_fields_of_the_wrong_type
    # A gateway's JSON that looks like an envelope but is not one.
    body = { "error" => { "type" => ["x"], "message" => { "text" => "x" }, "request_id" => 7,
                          "details" => { "code" => "x" } } }
    error = failure(raw(Nohead::Response.new(502, { "content-type" => "application/json", "x-request-id" => "req_9" },
                                             JSON.generate(body))))
    assert_instance_of Nohead::InternalServerError, error
    assert_equal [nil, "req_9", []], [error.type, error.request_id, error.details]
    assert_equal "502 error: Request failed with status 502 (request req_9)", error.to_s
  end

  def test_details_that_are_not_objects_are_kept_as_text
    detail = { "code" => "revision_mismatch", "message" => "x", "current_revision" => 7 }
    error = failure(raw(api_error(412, "precondition_failed", {}, details: [1, nil, "x", [2], detail])))
    assert_equal([%w[unknown 1], %w[unknown null], %w[unknown x], %w[unknown [2]], %w[revision_mismatch x]],
                 error.details.map { |item| [item.code, item.message] })
    assert_equal 7, error.current_revision
  end

  def test_the_apis_own_message
    assert_equal "not_found message", failure(api_error(404, "not_found")).api_message
    html = Nohead::Response.new(502, { "content-type" => "text/html" }, "<html>Bad gateway</html>")
    assert_equal "Request failed with status 502", failure(raw(html)).api_message
  end

  # A redirect means the base URL is off (http for https, a missing path):
  # following it could send the key somewhere else, and drops a POST's body.
  def test_redirects_are_errors
    moved = Nohead::Response.new(301, { "location" => "https://api.nohead.io/v1/records/rec_1" }, "")
    nohead, transport = client([raw(moved)])
    error = assert_raises(Nohead::APIError) { nohead.records.get("rec_1") }
    assert_instance_of Nohead::APIError, error
    assert_equal "redirect", error.type
    assert_equal "301 redirect: The API answered with a redirect to https://api.nohead.io/v1/records/rec_1; " \
                 "check the base URL", error.message
    assert_equal "The API answered with a redirect to https://api.nohead.io/v1/records/rec_1; check the base URL",
                 error.api_message
    assert_equal 1, transport.requests.size

    error = failure(raw(api_error(302, "not_found")))
    assert_instance_of Nohead::APIError, error
    assert_equal "302 redirect: The API answered with a redirect; check the base URL", error.message
  end

  def test_unknown_types_stay_api_errors
    assert_instance_of Nohead::APIError, failure(raw(api_error(418, "teapot_error")))
  end
end
