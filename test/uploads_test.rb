# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class UploadsTest < Minitest::Test
  include Helpers

  def asset(status)
    { id: "ast_1", object: "asset", filename: "a.png", content_type: "image/png", byte_size: 3,
      status: status }
  end

  def created
    json(201, { object: "asset_upload", asset: asset("pending"),
                upload: { method: "PUT", url: "https://storage.test/uploads/prj_1/ast_1?signature=x",
                          headers: { "Content-Type" => "image/png" },
                          expires_at: "2026-10-02T13:00:00.000Z" } })
  end

  def stored = Nohead::Response.new(200, {}, "")
  def ready = json(200, asset("ready"))

  def test_uploads_a_path
    Dir.mktmpdir do |dir|
      path = File.join(dir, "a.png")
      File.binwrite(path, "\x01\x02\x03")
      nohead, transport = client([created, stored, ready], timeout: 9)
      assert_equal "ready", nohead.assets.upload(path).status
      assert_equal(["POST api.test/v1/projects/prj_1/assets/uploads", "PUT storage.test/uploads/prj_1/ast_1",
                    "POST api.test/v1/assets/ast_1/complete"],
                   transport.requests.map { |request| "#{request.method} #{request.uri.host}#{request.path}" })
      assert_equal({ "filename" => "a.png", "content_type" => "image/png", "byte_size" => 3 },
                   transport.requests.first.json)
      put = transport.requests[1]
      assert_equal "\x01\x02\x03".b, put.body.b
      assert_equal "3", put.headers["Content-Length"]
      assert_equal "image/png", put.headers["Content-Type"]
      refute put.headers.key?("Authorization")
      assert_equal 9, put.timeout
    end
  end

  def test_uses_an_idempotency_key_only_to_start_the_upload
    nohead, transport = client([created, stored, ready])
    nohead.assets.upload(StringIO.new("x"), idempotency_key: "k1")
    keys = transport.requests.map { |request| request.headers["Idempotency-Key"] }
    assert_equal "k1", keys[0]
    assert_match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/, keys[2])
  end

  def test_uploads_bytes_in_a_stringio
    nohead, transport = client([created, stored, ready])
    nohead.assets.upload(StringIO.new("0123456789"), filename: "data.bin")
    assert_equal({ "filename" => "data.bin", "content_type" => "application/octet-stream",
                   "byte_size" => 10 }, transport.requests.first.json)
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

  def test_storage_refusing_the_bytes
    nohead, = client([created, Nohead::Response.new(403, {}, "denied")])
    error = assert_raises(Nohead::UploadError) { nohead.assets.upload(StringIO.new("x")) }
    assert_equal 403, error.status
  end

  def test_a_file_that_fails_the_checks
    nohead, = client([created, stored, api_error(422, "validation_error")], max_retries: 0)
    assert_raises(Nohead::ValidationError) { nohead.assets.upload(StringIO.new("x")) }
  end
end
