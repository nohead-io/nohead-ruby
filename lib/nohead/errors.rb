# frozen_string_literal: true

module Nohead
  # The base of every error the SDK raises.
  class Error < StandardError; end

  # The API answered with an error status. Subclasses follow the error `type`.
  class APIError < Error
    # The HTTP status.
    attr_reader :status
    # The error `type`, e.g. "validation_error"; nil if the body had none.
    attr_reader :type
    # The request's ID ("req_..."), for support requests and logs.
    attr_reader :request_id
    # Field-level details: objects with `field`, `code` and `message`.
    attr_reader :details
    # The response headers (lowercase names).
    attr_reader :headers
    # The parsed response body, or its text when it was not JSON.
    attr_reader :body

    def initialize(status, body, headers)
      error = Nohead.error_envelope(body)
      @status = status
      @type = error["type"]
      @request_id = error["request_id"] || headers["x-request-id"]
      @details = Array(error["details"]).map { |detail| NoheadObject.wrap(detail) }
      @headers = headers
      @body = body
      super(error["message"] || "Request failed with status #{status}")
    end

    def to_s
      suffix = request_id ? " (request #{request_id})" : ""
      "#{status} #{type || 'error'}: #{super}#{suffix}"
    end
  end

  class InvalidRequestError < APIError; end
  class AuthenticationError < APIError; end
  class PlanLimitExceededError < APIError; end
  class AuthorizationError < APIError; end
  class NotFoundError < APIError; end
  class ConflictError < APIError; end

  # An `if_match` revision was not the current one: reload and try again.
  class PreconditionFailedError < APIError
    # The resource's current revision, when the API reports it.
    def current_revision
      details.find { |detail| detail["code"] == "revision_mismatch" }&.[]("current_revision")
    end
  end

  class ValidationError < APIError; end

  class RateLimitError < APIError
    # Seconds to wait before retrying, from `Retry-After`.
    def retry_after
      Nohead.retry_after_seconds(headers)
    end
  end

  class InternalServerError < APIError; end
  class ServiceUnavailableError < APIError; end

  # The request never got a response: DNS, TLS, a reset connection.
  class ConnectionError < Error; end

  # An attempt took longer than the `timeout` option.
  class TimeoutError < ConnectionError; end

  # A presigned upload to storage failed (`assets.upload`).
  class UploadError < Error
    # Storage's HTTP status, when it answered.
    attr_reader :status

    def initialize(message, status = nil)
      @status = status
      super(message)
    end
  end

  # A webhook request's signature or timestamp did not check out.
  class WebhookVerificationError < Error; end

  ERROR_CLASSES = {
    "invalid_request" => InvalidRequestError,
    "authentication_error" => AuthenticationError,
    "plan_limit_exceeded" => PlanLimitExceededError,
    "authorization_error" => AuthorizationError,
    "not_found" => NotFoundError,
    "conflict" => ConflictError,
    "precondition_failed" => PreconditionFailedError,
    "validation_error" => ValidationError,
    "rate_limited" => RateLimitError,
    "internal_error" => InternalServerError,
    "service_unavailable" => ServiceUnavailableError
  }.freeze

  # The error for a response, by its `type`, or by status when it has none.
  def self.api_error(status, body, headers)
    klass = ERROR_CLASSES[error_envelope(body)["type"]] ||
            if status == 503 then ServiceUnavailableError
            elsif status >= 500 then InternalServerError
            else APIError
            end
    klass.new(status, body, headers)
  end

  # The error envelope's fields that have the right type: a proxy or gateway
  # in front of the API may answer with any JSON.
  def self.error_envelope(body)
    error = body["error"] if body.is_a?(Hash)
    return {} unless error.is_a?(Hash)

    fields = error.slice("type", "message", "request_id").select { |_, value| value.is_a?(String) }
    fields["details"] = error["details"] if error["details"].is_a?(Array)
    fields
  end

  def self.retry_after_seconds(headers)
    value = headers["retry-after"] or return nil
    return [Float(value), 0].max if value.match?(/\A\d+(\.\d+)?\z/)

    [Time.httpdate(value) - Time.now, 0].max
  rescue ArgumentError
    nil
  end
end
