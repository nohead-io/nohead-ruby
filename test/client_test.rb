# frozen_string_literal: true

require_relative "test_helper"

class ClientTest < Minitest::Test
  include Helpers

  def with_env(values)
    saved = values.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| ENV[key] = value }
  end

  def test_needs_an_api_key
    with_env("NOHEAD_API_KEY" => "") do
      assert_raises(Nohead::Error) { Nohead::Client.new }
    end
  end

  def test_reads_the_environment
    with_env("NOHEAD_API_KEY" => "sk_live_env", "NOHEAD_API_URL" => "https://env.test/") do
      transport = FakeTransport.new([json(200, record("rec_1"))])
      Nohead::Client.new(transport: transport).records.get("rec_1")
      request = transport.requests.first
      assert_equal "https://env.test/v1/records/rec_1", request.url
      assert_equal "Bearer sk_live_env", request.headers["Authorization"]
    end
  end

  def test_identifies_itself
    nohead, transport = client([json(200, record("rec_1"))], headers: { "X-Extra" => "yes" })
    nohead.records.get("rec_1")
    headers = transport.requests.first.headers
    assert_equal "sdk-ruby/#{Nohead::VERSION}", headers["Nohead-Client"]
    assert_equal "application/json", headers["Accept"]
    assert_equal "yes", headers["X-Extra"]
  end

  def test_version_matches_the_changelog
    assert_includes File.read(File.expand_path("../CHANGELOG.md", __dir__), encoding: "UTF-8"),
                    "## #{Nohead::VERSION}"
  end

  ME = { object: "principal", type: "api_key", user: nil,
         api_key: { id: "key_1", project_id: "prj_9", scopes: [] } }.freeze

  def test_looks_up_the_project_once
    nohead, transport = client([json(200, ME), page([], nil)], project_id: nil)
    nohead.collections.list
    nohead.webhooks.list
    assert_equal ["/v1/me", "/v1/projects/prj_9/collections", "/v1/projects/prj_9/webhooks"],
                 transport.requests.map(&:path)
  end

  def test_without_a_project_key
    me = { object: "principal", type: "user", user: {}, api_key: nil }
    nohead, = client([json(200, me)], project_id: nil)
    error = assert_raises(Nohead::Error) { nohead.collections.list }
    assert_match(/not a project API key/, error.message)
  end

  def test_objects_read_like_the_api
    nohead, = client([json(200, record("rec_1", title: "Hi").merge(brand_new: 1))])
    post = nohead.records.get("rec_1")
    assert_equal "Hi", post.data["title"]
    assert_equal "Hi", post.data.title
    assert_equal "Hi", post[:data][:title]
    assert_equal 1, post.brand_new
    assert_equal Time.utc(2026, 10, 2, 12), post.created_at
    assert_nil post.schedule.publish_at
    assert_respond_to post, :revision
    refute_respond_to post, :nothing_like_it
  end
end
