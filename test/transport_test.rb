# frozen_string_literal: true

require_relative "test_helper"

# How the transport sets up Net::HTTP, and what it makes of Net::HTTP's
# errors. What goes over the wire is network_test.rb's.
class TransportTest < Minitest::Test
  FakeResponse = Struct.new(:code, :body) do
    def each_header = { "content-type" => "application/json" }.each
  end

  # For the block, Net::HTTP.new hands out connections that answer with
  # `reply` (called with the request) instead of reaching the network; yields
  # them.
  def offline(reply)
    connections = []
    http_class = Net::HTTP.singleton_class
    real = http_class.instance_method(:new)
    http_class.remove_method(:new) # redefining it would warn
    http_class.define_method(:new) do |*args|
      real.bind_call(self, *args).tap do |http|
        http.define_singleton_method(:start) { |&block| block.call(self) }
        http.define_singleton_method(:request) { |request, *| reply.call(request) }
        connections << http
      end
    end
    yield connections
  ensure
    http_class.remove_method(:new)
    http_class.define_method(:new, real)
  end

  def send_request
    Nohead::Transport.new.call("POST", "https://api.test/v1/records?x=1", {}, nil, 5)
  end

  def test_sets_every_timeout
    offline(->(_) { FakeResponse.new("200", "") }) do |connections|
      send_request
      assert_equal 1, connections.size
      http = connections.first
      assert_equal [5, 5, 5], [http.open_timeout, http.read_timeout, http.write_timeout]
      assert_equal 0, http.max_retries # the client's retries are the only ones
      assert_predicate http, :use_ssl?
      assert_predicate http, :proxy_from_env?
    end
  end

  # The real server in network_test.rb shows a stall and a broken status
  # line; these are the rest.
  def test_maps_net_http_errors
    timeout = [Nohead::TimeoutError, "The request to api.test timed out after 5 s"]
    unread = [Nohead::ConnectionError, "The response from api.test could not be read: broken"]
    unreached = [Nohead::ConnectionError, "Could not reach api.test: broken"]
    {
      Net::OpenTimeout => timeout, Net::ReadTimeout => timeout, Net::WriteTimeout => timeout,
      Net::HTTPBadResponse => unread, Net::HTTPHeaderSyntaxError => unread, Net::ProtocolError => unread,
      Zlib::DataError => unread,
      SocketError => unreached, IOError => unreached, OpenSSL::SSL::SSLError => unreached,
      Errno::ECONNREFUSED => [Nohead::ConnectionError, "Could not reach api.test: Connection refused - broken"]
    }.each do |error, (expected, message)|
      offline(->(_) { raise error, "broken" }) do
        raised = assert_raises(Nohead::Error, error.name) { send_request }
        assert_equal [expected, message], [raised.class, raised.message], error.name
      end
    end
  end
end
