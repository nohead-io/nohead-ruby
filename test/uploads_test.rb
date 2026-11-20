# frozen_string_literal: true

require_relative "test_helper"
require "timeout"
require "tmpdir"

class UploadsTest < Minitest::Test
  include Helpers

  def asset(status)
    example("assets_get", id: "ast_1", filename: "a.png", content_type: "image/png", byte_size: 3, status: status)
  end

  def created(expires_at: (Time.now + 900).utc.iso8601(3))
    json(201, asset("pending").merge(upload: { method: "PUT", url: "https://storage.test/uploads/prj_1/ast_1?signature=x",
                                               headers: { "Content-Type" => "image/png" },
                                               expires_at: expires_at }))
  end

  def stored = Nohead::Response.new(200, {}, "")
  def ready = json(200, asset("ready"))

  def test_uploads_a_path
    Dir.mktmpdir do |dir|
      path = File.join(dir, "a.png")
      File.binwrite(path, "\x01\x02\x03")
      nohead, transport = client([created, stored, ready], timeout: 9)
      assert_equal "ready", nohead.assets.upload(path).status
      assert_equal(["POST api.test/v1/projects/prj_1/assets", "PUT storage.test/uploads/prj_1/ast_1",
                    "POST api.test/v1/assets/ast_1/complete"],
                   transport.requests.map { |request| "#{request.method} #{request.uri.host}#{request.path}" })
      # No type given: the API types the file by its name.
      assert_equal({ "filename" => "a.png", "byte_size" => 3 },
                   transport.requests.first.json)
      put = transport.requests[1]
      assert_equal "\x01\x02\x03".b, put.body.b
      assert_equal "3", put.headers["Content-Length"]
      assert_equal "image/png", put.headers["Content-Type"]
      refute put.headers.key?("Authorization")
      assert_equal 9, put.timeout
    end
  end

  def test_sends_alt_text_with_the_start_of_the_upload_and_none_unless_given
    nohead, transport = client([created, stored, ready, created, stored, ready])
    nohead.assets.upload(StringIO.new("x"), filename: "harbour.png", alt: "A harbour")
    assert_equal "A harbour", transport.requests[0].json["alt"]
    nohead.assets.upload(StringIO.new("x"), filename: "harbour.png")
    refute transport.requests[3].json.key?("alt")
  end

  def test_uses_an_idempotency_key_only_to_start_the_upload
    nohead, transport = client([created, json(200, asset("pending")), stored, ready])
    assert_equal "ready", nohead.assets.upload(StringIO.new("x"), idempotency_key: "k1").status
    assert_equal(["POST /v1/projects/prj_1/assets", "GET /v1/assets/ast_1", "PUT /uploads/prj_1/ast_1",
                  "POST /v1/assets/ast_1/complete"],
                 transport.requests.map { |request| "#{request.method} #{request.path}" })
    keys = transport.requests.map { |request| request.headers["Idempotency-Key"] }
    assert_equal "k1", keys[0]
    assert_nil keys[1]
    assert_match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/, keys[3])
  end

  def test_resumes_an_upload_that_is_already_done
    nohead, transport = client([created, ready])
    assert_equal "ready", nohead.assets.upload(StringIO.new("x"), idempotency_key: "k1").status
    assert_equal(["POST /v1/projects/prj_1/assets", "GET /v1/assets/ast_1"],
                 transport.requests.map { |request| "#{request.method} #{request.path}" })
  end

  def test_refuses_to_resume_once_the_upload_url_expired
    nohead, transport = client([created(expires_at: "2026-10-02T13:00:00.000Z"), json(200, asset("pending"))])
    error = assert_raises(Nohead::UploadError) do
      nohead.assets.upload(StringIO.new("x"), idempotency_key: "k1")
    end
    assert_match(/new idempotency_key/, error.message)
    assert_equal %w[POST GET], transport.requests.map(&:method)
  end

  def test_checks_for_a_finished_upload_only_with_an_idempotency_key
    [nil, ""].each do |key|
      nohead, transport = client([created, stored, ready])
      nohead.assets.upload(StringIO.new("x"), idempotency_key: key)
      assert_equal %w[POST PUT POST], transport.requests.map(&:method), "idempotency_key: #{key.inspect}"
    end
  end

  # Files of "hello world", by kind, with the requests made before a short
  # one fails: none when its size is known. Each its own test.
  SOURCES = {
    "stringio" => [->(_dir) { StringIO.new("hello world") }, []],
    "path" => [->(dir) { File.join(dir, "a.txt").tap { |path| File.binwrite(path, "hello world") } }, []],
    "pipe" => [lambda do |_dir|
      reader, writer = IO.pipe
      writer.write("hello world")
      writer.close
      reader
    end, %w[POST]]
  }.freeze

  SOURCES.each do |kind, (source, requests)|
    define_method("test_sends_byte_size_bytes_at_most_of_a_#{kind}") do
      Dir.mktmpdir do |dir|
        nohead, transport = client([created, stored, ready])
        nohead.assets.upload(source.call(dir), filename: "a.txt", byte_size: 5)
        assert_equal 5, transport.requests[0].json["byte_size"]
        assert_equal "hello", transport.requests[1].body
      end
    end

    define_method("test_refuses_a_#{kind}_shorter_than_its_byte_size") do
      Dir.mktmpdir do |dir|
        nohead, transport = client([created, stored, ready])
        error = assert_raises(Nohead::UploadError) do
          nohead.assets.upload(source.call(dir), filename: "a.txt", byte_size: 20)
        end
        assert_match(/\ACould not upload a.txt: it has 11 bytes, fewer/, error.message)
        assert_equal requests, transport.requests.map(&:method)
      end
    end
  end

  # Its size on disk is 0, whatever it holds.
  def test_uploads_a_named_pipe_with_its_byte_size
    Dir.mktmpdir do |dir|
      fifo = File.join(dir, "fifo")
      File.mkfifo(fifo)
      writer = Thread.new { File.binwrite(fifo, "hello") }
      begin
        nohead, transport = client([created, stored, ready])
        nohead.assets.upload(fifo, byte_size: 5)
        assert writer.join(5), "the writer finished"
        assert_equal "hello", transport.requests[1].body
      ensure
        writer.kill # blocked opening the pipe if the upload never did
      end
    end
  end

  # A device's size (0) isn't what it holds: its byte_size is.
  def test_uploads_a_device_with_its_byte_size
    File.open("/dev/zero", "rb") do |zero|
      nohead, transport = client([created, stored, ready])
      nohead.assets.upload(zero, byte_size: 5)
      assert_equal "\0" * 5, transport.requests[1].body
    end
  end

  # A path that can't be read fails as opening it would (or, for a
  # directory, reading it), whether or not byte_size is given.
  def test_a_path_that_cannot_be_read
    Dir.mktmpdir do |dir|
      { "missing.png" => Errno::ENOENT, "." => Errno::EISDIR }.each do |name, error|
        [nil, 5].each do |byte_size|
          nohead, transport = client([created])
          assert_raises(error, "#{name}, byte_size: #{byte_size.inspect}") do
            nohead.assets.upload(File.join(dir, name), byte_size: byte_size)
          end
          assert_empty transport.requests
        end
      end
    end
  end

  # A transport of one's own reads the upload as an IO, here as Net::HTTP
  # does (IO.copy_stream, in chunks into a buffer): byte_size bytes.
  class CopyingTransport < FakeTransport
    attr_reader :size

    def call(method, url, headers, body, timeout)
      if body.respond_to?(:read)
        @size = body.size
        copy = StringIO.new
        IO.copy_stream(body, copy)
        body = copy.string
      end
      super
    end
  end

  # Reads the upload as http.rb does: what it has so far, then (once `more`
  # has run) the rest.
  class PartialTransport < FakeTransport
    attr_reader :partial

    def initialize(replies, more)
      super(replies)
      @more = more
    end

    def call(method, url, headers, body, timeout)
      if body.respond_to?(:read)
        @partial = body.readpartial(1024)
        @more.call
        body = @partial + body.read
      end
      super
    end
  end

  def test_a_transport_reads_what_a_pipe_has_so_far
    reader, writer = IO.pipe
    writer.write("hello")
    transport = PartialTransport.new([created, stored, ready], lambda {
      writer.write(" world!")
      writer.close
    })
    nohead = Nohead::Client.new(api_key: "nohead_sk_test", base_url: "https://api.test", project_id: "prj_1",
                                transport: transport)
    Timeout.timeout(5) { nohead.assets.upload(reader, byte_size: 11) }
    assert_equal "hello", transport.partial
    assert_equal "hello world", transport.requests[1].body
  ensure
    reader&.close
    writer&.close
  end

  def test_a_transport_of_its_own_reads_the_upload_as_an_io
    transport = CopyingTransport.new([created, stored, ready])
    nohead = Nohead::Client.new(api_key: "nohead_sk_test", base_url: "https://api.test", project_id: "prj_1",
                                transport: transport)
    nohead.assets.upload(StringIO.new("hello world"), byte_size: 5)
    assert_equal 5, transport.size
    assert_equal "hello", transport.requests[1].body
  end

  # A device's size on disk (0) isn't what it holds.
  def test_needs_byte_size_for_a_path_that_is_not_a_file
    nohead, transport = client([created])
    error = assert_raises(Nohead::UploadError) { nohead.assets.upload(File::NULL, filename: "a.txt") }
    assert_equal "Uploading null, which is not a file, needs byte_size:", error.message
    assert_empty transport.requests
  end

  def test_needs_byte_size_for_an_open_device
    File.open(File::NULL, "rb") do |device|
      nohead, transport = client([created])
      error = assert_raises(Nohead::UploadError) { nohead.assets.upload(device) }
      assert_equal "Uploading a stream that isn't a file needs byte_size:", error.message
      assert_empty transport.requests
    end
  end

  # As a pipe's own rewind: its bytes can't be sent again.
  def test_a_pipe_cannot_rewind
    reader, writer = IO.pipe
    assert_raises(Errno::ESPIPE) { Nohead::UploadSource.new(reader, byte_size: 5).rewind }
  ensure
    reader&.close
    writer&.close
  end

  def test_uploads_bytes_in_a_stringio
    nohead, transport = client([created, stored, ready])
    nohead.assets.upload(StringIO.new("0123456789"), filename: "data.bin")
    assert_equal({ "filename" => "data.bin", "byte_size" => 10 }, transport.requests.first.json)
  end

  def test_sends_a_content_type_only_when_given
    nohead, transport = client([created, stored, ready])
    nohead.assets.upload(StringIO.new("x"), filename: "notes.md", content_type: "text/plain")
    assert_equal "text/plain", transport.requests.first.json["content_type"]
  end

  def test_an_empty_filename_or_content_type_is_the_default
    nohead, transport = client([created, stored, ready])
    nohead.assets.upload(StringIO.new("x"), filename: "", content_type: "")
    assert_equal({ "filename" => "upload", "byte_size" => 1 }, transport.requests.first.json)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "a.png")
      File.binwrite(path, "x")
      nohead, transport = client([created, stored, ready])
      nohead.assets.upload(path, filename: "", content_type: "")
      assert_equal({ "filename" => "a.png", "byte_size" => 1 }, transport.requests.first.json)
    end
  end

  def test_needs_byte_size_for_a_stream
    nohead, = client([created])
    IO.pipe do |reader, _writer|
      assert_raises(Nohead::UploadError) { nohead.assets.upload(reader) }
    end
  end

  def test_retries_the_bytes_on_a_server_error
    nohead, transport = client([created, Nohead::Response.new(503, {}, ""), stored, ready])
    nohead.assets.upload(StringIO.new("x"))
    assert_equal(["POST api.test", "PUT storage.test", "PUT storage.test", "POST api.test"],
                 transport.requests.map { |request| "#{request.method} #{request.uri.host}" })
    assert_equal "x", transport.requests[2].body
  end

  # A pipe (like $stdin) can't seek: its bytes go once, and a server error is
  # the upload's failure.
  def test_on_retry_hears_of_upload_retries
    events = []
    replies = [created, Nohead::Response.new(503, {}, ""), Nohead::ConnectionError.new("reset"), stored, ready]
    nohead, = client(replies, on_retry: ->(event) { events << event })
    nohead.assets.upload(StringIO.new("x"))
    url = "https://storage.test/uploads/prj_1/ast_1?signature=x"
    assert_equal([[1, url, 503, nil], [2, url, nil, "reset"]],
                 events.map { |event| [event.attempt, event.url, event.status, event.error&.message] })
  end

  def test_does_not_retry_bytes_it_cannot_read_again
    nohead, transport = client([created, Nohead::Response.new(503, {}, ""), stored, ready])
    IO.pipe do |reader, writer|
      writer.write("x")
      writer.close
      error = assert_raises(Nohead::UploadError) { nohead.assets.upload(reader, byte_size: 1) }
      assert_equal 503, error.status
    end
    assert_equal %w[POST PUT], transport.requests.map(&:method)
    assert_equal "x", transport.requests[1].body
  end

  def test_does_not_retry_an_io_without_a_position
    io = Object.new
    def io.read(*) = "x"
    nohead, transport = client([created, Nohead::Response.new(503, {}, ""), stored, ready])
    error = assert_raises(Nohead::UploadError) { nohead.assets.upload(io, byte_size: 1) }
    assert_equal 503, error.status
    assert_equal %w[POST PUT], transport.requests.map(&:method)
  end

  def test_retries_the_bytes_from_where_the_io_was
    io = StringIO.new("skip:bytes")
    io.read(5)
    nohead, transport = client([created, Nohead::Response.new(503, {}, ""), stored, ready])
    nohead.assets.upload(io)
    assert_equal 5, transport.requests.first.json["byte_size"]
    assert_equal(%w[bytes bytes], transport.requests.select { |request| request.method == "PUT" }.map(&:body))
  end

  def test_storage_failing_every_attempt
    nohead, transport = client([created, Nohead::Response.new(503, {}, "")])
    error = assert_raises(Nohead::UploadError) { nohead.assets.upload(StringIO.new("x")) }
    assert_equal 503, error.status
    assert_match(/503/, error.message)
    assert_equal %w[POST PUT PUT PUT], transport.requests.map(&:method)
  end

  def test_storage_out_of_reach
    [Nohead::ConnectionError.new("Could not reach storage.test: refused"),
     Nohead::TimeoutError.new("The request to storage.test timed out after 60 s")].each do |failure|
      nohead, transport = client([created, failure])
      error = assert_raises(Nohead::UploadError) { nohead.assets.upload(StringIO.new("x"), filename: "a.png") }
      assert_equal "Could not upload a.png: #{failure.message}", error.message
      assert_same failure, error.cause
      assert_nil error.status
      assert_equal %w[POST PUT PUT PUT], transport.requests.map(&:method)
    end
  end

  def test_storage_refusing_the_bytes
    nohead, = client([created, Nohead::Response.new(403, {}, "denied")])
    error = assert_raises(Nohead::UploadError) { nohead.assets.upload(StringIO.new("x"), filename: "a.png") }
    assert_equal 403, error.status
    assert_equal "Storage refused the upload of a.png (403)", error.message
  end

  def test_does_not_follow_a_redirect_from_storage
    moved = Nohead::Response.new(307, { "location" => "https://elsewhere.test/" }, "")
    nohead, transport = client([created, moved, stored, ready])
    error = assert_raises(Nohead::UploadError) { nohead.assets.upload(StringIO.new("x")) }
    assert_equal 307, error.status
    assert_equal %w[POST PUT], transport.requests.map(&:method)
  end

  def test_a_file_that_fails_the_checks
    nohead, = client([created, stored, api_error(422, "validation_error")], max_retries: 0)
    assert_raises(Nohead::ValidationError) { nohead.assets.upload(StringIO.new("x")) }
  end
end
