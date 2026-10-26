# frozen_string_literal: true

require_relative "test_helper"
require_relative "local_server"

# The client over its real transport (Net::HTTP) against a real HTTP server
# on 127.0.0.1: what goes over the wire, which the fake transport can't show.
class NetworkTest < Minitest::Test
  include Helpers

  TIMEOUT = 0.3

  def serve(handler, max_retries: 0, &)
    LocalServer.open(handler) do |server|
      nohead = Nohead::Client.new(api_key: "nohead_sk_test", base_url: server.url(""), project_id: "prj_1",
                                  max_retries: max_retries, timeout: TIMEOUT)
      yield nohead, server
    end
  end

  def head(socket, body, status = 200)
    socket.write("HTTP/1.1 #{status} Status\r\nContent-Type: application/json\r\n" \
                 "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n")
  end

  def asset(status, **fields)
    JSON.generate(example("assets_get", id: "ast_1", filename: "a.txt", content_type: "text/plain",
                                        byte_size: 5, status: status, **fields))
  end

  # The API's side of an upload, with `storage` answering the PUT.
  def uploads(storage)
    lambda do |request, socket|
      case [request.method, request.path]
      in ["POST", "/v1/projects/prj_1/assets"]
        upload = { method: "PUT", url: "http://#{request.headers['host']}/storage/ast_1?signature=x",
                   headers: { "Content-Type" => "text/plain" }, expires_at: (Time.now + 900).utc.iso8601(3) }
        LocalServer.reply(socket, 201, asset("pending", upload: upload), "Content-Type" => "application/json")
      in ["PUT", "/storage/ast_1?signature=x"] then storage.call(request, socket)
      in ["POST", "/v1/assets/ast_1/complete"]
        LocalServer.reply(socket, 200, asset("ready"), "Content-Type" => "application/json")
      end
    end
  end

  def pipe(bytes)
    reader, writer = IO.pipe
    writer.write(bytes)
    writer.close
    reader
  end

  def test_streams_an_upload_from_a_pipe_with_its_content_length
    reader = pipe("hello")
    serve(uploads(->(_, socket) { LocalServer.reply(socket, 200) })) do |nohead, server|
      assert_equal "ready", nohead.assets.upload(reader, filename: "a.txt", byte_size: 5).status
      put = server.requests.find { |request| request.method == "PUT" }
      assert_equal "5", put.headers["content-length"]
      refute put.chunked, "the upload is not chunked (storage's signature covers its length)"
      assert_equal "hello", put.body
      assert_equal "text/plain", put.headers["content-type"]
      refute put.headers.key?("authorization")
    end
  ensure
    reader&.close
  end

  # Net::HTTP would send it again once on its own, with the pipe already read.
  def test_sends_a_stream_that_stalls_once
    reader = pipe("hello")
    serve(uploads(->(_, _) { sleep }), max_retries: 2) do |nohead, server|
      error = assert_raises(Nohead::UploadError) { nohead.assets.upload(reader, byte_size: 5) }
      assert_kind_of Nohead::TimeoutError, error.cause
      assert_equal %w[POST PUT], server.requests.map(&:method)
      assert_equal 2, server.connections
    end
  ensure
    reader&.close
  end

  # The client retries an upload it can replay, with the whole body again.
  def test_retries_an_upload_with_every_byte
    refused = false
    storage = lambda do |_, socket|
      LocalServer.reply(socket, refused ? 200 : 503)
      refused = true
    end
    serve(uploads(storage), max_retries: 1) do |nohead, server|
      assert_equal "ready", nohead.assets.upload(StringIO.new("hello"), filename: "a.txt").status
      sent = server.requests.select { |request| request.method == "PUT" }
      assert_equal([%w[5 hello]] * 2, sent.map { |put| [put.headers["content-length"], put.body] })
    end
  end

  # The timeout is the longest wait without progress, not the whole request's.
  def test_a_response_that_keeps_arriving_does_not_time_out
    body = JSON.generate(record("rec_1", title: "Slow"))
    pieces = body.chars.each_slice((body.size / 7.0).ceil).map(&:join)
    handler = lambda do |_, socket|
      head(socket, body)
      pieces.each do |piece|
        sleep(TIMEOUT / 3)
        socket.write(piece)
      end
    end
    serve(handler) do |nohead|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_equal "Slow", nohead.records.get("rec_1").data["title"]
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :>, 2 * TIMEOUT
    end
  end

  def test_a_response_that_stalls_times_out
    body = JSON.generate(record("rec_1", title: "Stalled"))
    stalls = {
      "before the response" => ->(_, _) { sleep },
      "in the body" => lambda do |_, socket|
        head(socket, body)
        socket.write(body[0, 10])
        sleep
      end
    }
    stalls.each do |where, handler|
      serve(handler) do |nohead, server|
        error = assert_raises(Nohead::TimeoutError, where) { nohead.records.get("rec_1") }
        assert_equal "The request to 127.0.0.1 timed out after #{TIMEOUT} s", error.message
        assert_equal 1, server.connections, "sent once: the client's retries are the only ones"
      end
    end
  end

  def test_a_dropped_connection_is_a_connection_error
    serve(->(_, _) {}) do |nohead, server|
      error = assert_raises(Nohead::ConnectionError) { nohead.webhooks.delete("wh_1") }
      refute_kind_of Nohead::TimeoutError, error
      assert_equal 1, server.connections
    end
  end

  def test_does_not_follow_a_redirect
    [301, 302].each do |status|
      handler = lambda do |request, socket|
        LocalServer.reply(socket, status, "", "Location" => "http://#{request.headers['host']}/v1/records/rec_2")
      end
      serve(handler) do |nohead, server|
        error = assert_raises(Nohead::APIError) { nohead.records.get("rec_1") }
        assert_equal [status, "redirect"], [error.status, error.type]
        assert_equal ["/v1/records/rec_1"], server.requests.map(&:path)
      end
    end
  end

  def test_a_malformed_response_is_a_connection_error
    serve(->(_, socket) { socket.write("garbage\r\n\r\n") }) do |nohead|
      error = assert_raises(Nohead::ConnectionError) { nohead.records.get("rec_1") }
      refute_kind_of Nohead::TimeoutError, error
      assert_match(/\AThe response from 127.0.0.1 could not be read: /, error.message)
    end
  end
end
