# frozen_string_literal: true

require "net/http"
require "openssl"
require "uri"
require "zlib"

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
      # No retries of its own (it retries a GET, PUT or DELETE that times out
      # or loses its connection once, and a PUT with the stream already
      # read): the client retries, and knows when it can.
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: timeout,
                                                     read_timeout: timeout, write_timeout: timeout,
                                                     max_retries: 0) do |http|
        http.request(request)
      end
      Response.new(response.code.to_i, response.each_header.to_h, response.body.to_s)
    rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout
      raise TimeoutError, "The request to #{uri.host} timed out after #{timeout} s"
    rescue SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError => e
      raise ConnectionError, "Could not reach #{uri.host}: #{e.message}"
    # A broken status line, header or compressed body: retried like a dropped connection.
    rescue Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Net::ProtocolError, Zlib::Error => e
      raise ConnectionError, "The response from #{uri.host} could not be read: #{e.message}"
    end
  end
end
