# frozen_string_literal: true

require_relative "test_helper"

class TransportTest < Minitest::Test
  FakeResponse = Struct.new(:code, :body) do
    def each_header = { "content-type" => "application/json" }.each
  end

  # While `reply` is set, Net::HTTP connections answer with it (called with
  # the request) instead of reaching the network, and keep what was sent and
  # the last connection.
  module Offline
    class << self
      attr_accessor :reply, :sent, :connection
    end

    def start(&) = Offline.reply ? yield(self) : super

    def request(request, *, &)
      return super unless Offline.reply

      Offline.sent << request
      Offline.connection = self
      Offline.reply.call(request)
    end
  end
  Net::HTTP.prepend(Offline)

  def offline(reply)
    Offline.reply = reply
    Offline.sent = []
    yield Offline.sent
  ensure
    Offline.reply = nil
  end

  def send_request(body = nil, headers = {})
    Nohead::Transport.new.call("POST", "https://api.test/v1/records?x=1", headers, body, 5)
  end

  def test_sends_the_request_and_reads_the_response
    offline(->(_) { FakeResponse.new("201", '{"id":"rec_1"}') }) do |sent|
      response = send_request('{"data":{}}', { "Content-Type" => "application/json" })
      assert_equal 201, response.status
      assert_equal({ "content-type" => "application/json" }, response.headers)
      assert_equal '{"id":"rec_1"}', response.body
      assert_equal "POST", sent.first.method
      assert_equal "/v1/records?x=1", sent.first.path
      assert_equal "application/json", sent.first["Content-Type"]
      assert_equal '{"data":{}}', sent.first.body
    end
  end

  def test_sets_every_timeout
    offline(->(_) { FakeResponse.new("200", "") }) do
      send_request
      http = Offline.connection
      assert_equal [5, 5, 5], [http.open_timeout, http.read_timeout, http.write_timeout]
    end
  end

  def test_streams_an_io_body
    io = StringIO.new("bytes")
    offline(->(_) { FakeResponse.new("200", "") }) do |sent|
      send_request(io, { "Content-Length" => "5" })
      assert_same io, sent.first.body_stream
      assert_equal "5", sent.first["Content-Length"]
    end
  end

  def test_timeouts_raise_timeout_error
    [Net::OpenTimeout, Net::ReadTimeout].each do |error|
      offline(->(_) { raise error }) do
        assert_raises(Nohead::TimeoutError, error.name) { send_request }
      end
    end
  end

  def test_unreachable_hosts_raise_connection_error
    [Errno::ECONNREFUSED, SocketError].each do |error|
      offline(->(_) { raise error }) do
        assert_raises(Nohead::ConnectionError, error.name) { send_request }
      end
    end
  end
end
