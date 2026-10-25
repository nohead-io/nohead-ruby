# frozen_string_literal: true

require "json"
require "minitest"
require "uri"
require_relative "spec"

# A transport that answers from `replies` in order (the last one repeats) and
# records every request, with the timeout it was sent with. A reply is a
# Nohead::Response, an exception to raise, or a callable taking the request.
#
# Every request to the API (a /v1/ path) must match its operation in the
# contract, and every reply to it must be one the operation can send: a
# mismatch fails the test. A reply that breaks the contract on purpose (a
# gateway's HTML page, an unknown error type) is wrapped in Raw.
class FakeTransport
  Request = Struct.new(:method, :url, :headers, :body, :timeout) do # rubocop:disable Lint/StructNewOverride
    def uri = URI(url)
    def path = uri.path
    def params = URI.decode_www_form(uri.query.to_s).to_h
    def json = JSON.parse(body)
    def api? = path.start_with?("/v1/")
  end

  # A reply the contract check leaves alone.
  Raw = Struct.new(:response)

  attr_reader :requests

  def initialize(replies)
    @replies = replies
    @requests = []
  end

  def call(method, url, headers, body, timeout)
    body = body.read if body.respond_to?(:read)
    request = Request.new(method, url, headers, body, timeout)
    @requests << request
    check(request, Contract.request_problems(request)) if request.api?
    reply = @replies[[@requests.size - 1, @replies.size - 1].min]
    raise reply if reply.is_a?(Exception)

    reply = reply.call(request) if reply.respond_to?(:call)
    return reply.response if reply.is_a?(Raw)

    check(request, Contract.reply_problems(Spec.route_of(request.method, request.path), reply)) if request.api?
    reply
  end

  private

  # An Assertion, not a StandardError, so the SDK's error handling can't
  # swallow it.
  def check(request, problems)
    return if problems.empty?

    raise Minitest::Assertion, "#{request.method} #{request.path} breaks openapi.json: #{problems.join('; ')}"
  end
end
