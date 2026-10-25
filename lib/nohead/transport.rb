# frozen_string_literal: true

require "net/http"
require "openssl"
require "uri"

module Nohead
  # A response: status, headers (lowercase names) and body text.
  Response = Struct.new(:status, :headers, :body)

  # Sends requests with Net::HTTP. A client's `transport:` can be anything
  # with the same `call`, e.g. for tests.
  class Transport
    # `body` is a String, an IO (streamed, with Content-Length), or nil.
    def call(method, url, headers, body, timeout)
      uri = URI(url)
      request = Net::HTTPGenericRequest.new(method, !body.nil?, true, uri.request_uri, headers)
      if body.respond_to?(:read)
        request.body_stream = body
      elsif body
        request.body = body
      end
      # The proxy comes from the environment (http_proxy, no_proxy), as Net::HTTP.new.
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: timeout,
                                                     read_timeout: timeout, write_timeout: timeout) do |http|
        http.request(request)
      end
      Response.new(response.code.to_i, response.each_header.to_h, response.body.to_s)
    rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout
      raise TimeoutError, "The request to #{uri.host} timed out after #{timeout} s"
    rescue SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError => e
      raise ConnectionError, "Could not reach #{uri.host}: #{e.message}"
    end
  end
end
