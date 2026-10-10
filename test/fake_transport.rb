# frozen_string_literal: true

require "json"
require "uri"

# A transport that answers from `replies` in order (the last one repeats) and
# records every request, with the timeout it was sent with. A reply is a
# Nohead::Response, an exception to raise, or a callable taking the request.
class FakeTransport
  Request = Struct.new(:method, :url, :headers, :body, :timeout) do # rubocop:disable Lint/StructNewOverride
    def uri = URI(url)
    def path = uri.path
    def params = URI.decode_www_form(uri.query.to_s).to_h
    def json = JSON.parse(body)
  end

  attr_reader :requests

  def initialize(replies)
    @replies = replies
    @requests = []
  end

  def call(method, url, headers, body, timeout)
    body = body.read if body.respond_to?(:read)
    request = Request.new(method, url, headers, body, timeout)
    @requests << request
    reply = @replies[[@requests.size - 1, @replies.size - 1].min]
    raise reply if reply.is_a?(Exception)

    reply.respond_to?(:call) ? reply.call(request) : reply
  end
end
