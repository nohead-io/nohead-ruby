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
    with_env("NOHEAD_API_KEY" => "nohead_sk_env", "NOHEAD_API_URL" => "https://env.test/") do
      transport = FakeTransport.new([json(200, record("rec_1"))])
      Nohead::Client.new(transport: transport).records.get("rec_1")
      request = transport.requests.first
      assert_equal "https://env.test/v1/records/rec_1", request.url
      assert_equal "Bearer nohead_sk_env", request.headers["Authorization"]
    end
  end

  def test_empty_options_are_unset
    with_env("NOHEAD_API_KEY" => "nohead_sk_env", "NOHEAD_API_URL" => "https://env.test") do
      transport = FakeTransport.new([json(200, ME), page([])])
      Nohead::Client.new(api_key: "", base_url: "", project_id: "", transport: transport).collections.list
      assert_equal(%w[https://env.test/v1/me https://env.test/v1/projects/prj_9/collections],
                   transport.requests.map(&:url))
      assert_equal "Bearer nohead_sk_env", transport.requests.first.headers["Authorization"]
    end
  end

  def test_removes_every_trailing_slash
    nohead, transport = client([json(200, record("rec_1"))], base_url: "https://api.test/api//")
    nohead.records.get("rec_1")
    assert_equal "https://api.test/api/v1/records/rec_1", transport.requests.first.url
  end

  def test_refuses_a_base_url_that_is_not_http
    ["ftp://api.test", "api.test", "https:", "https://api test", "mailto:a@b.test"].each do |url|
      error = assert_raises(Nohead::Error, url) { Nohead::Client.new(api_key: "nohead_sk_x", base_url: url) }
      assert_equal "base_url must be an http or https URL", error.message
    end
    assert Nohead::Client.new(api_key: "nohead_sk_x", base_url: "HTTP://localhost:3000")
  end

  def test_defaults_to_production
    with_env("NOHEAD_API_URL" => "") do
      transport = FakeTransport.new([json(200, record("rec_1"))])
      Nohead::Client.new(api_key: "nohead_sk_x", transport: transport).records.get("rec_1")
      assert_equal "https://api.nohead.io/v1/records/rec_1", transport.requests.first.url
    end
  end

  def test_identifies_itself
    nohead, transport = client([json(200, record("rec_1"))], headers: { "X-Extra" => "yes" })
    nohead.records.get("rec_1")
    headers = transport.requests.first.headers
    assert_equal "sdk-ruby/#{Nohead::VERSION}", headers["Nohead-Client"]
    assert_equal "nohead-ruby/#{Nohead::VERSION} ruby/#{RUBY_VERSION}", headers["User-Agent"]
    assert_equal "application/json", headers["Accept"]
    assert_equal "yes", headers["X-Extra"]
  end

  def test_headers_nil_is_none
    nohead, transport = client([json(200, record("rec_1"))], headers: nil)
    nohead.with_options(headers: nil).records.get("rec_1")
    assert_equal "application/json", transport.requests.first.headers["Accept"]
  end

  def test_version_matches_the_changelog
    assert_includes File.read(File.expand_path("../CHANGELOG.md", __dir__), encoding: "UTF-8"),
                    "## #{Nohead::VERSION}"
  end

  ME = { object: "principal", type: "api_key", user: nil,
         api_key: { id: "key_1", name: "Importer", scopes: [], published_only: false, project_id: "prj_9",
                    expires_at: nil } }.freeze

  def test_looks_up_the_project_once
    nohead, transport = client([json(200, ME), page([])], project_id: nil)
    nohead.collections.list
    nohead.webhooks.list
    assert_equal ["/v1/me", "/v1/projects/prj_9/collections", "/v1/projects/prj_9/webhooks"],
                 transport.requests.map(&:path)
  end

  def test_looks_up_the_project_once_for_threads_at_the_same_time
    me = lambda do |request|
      next page([]) unless request.path == "/v1/me"

      sleep 0.05 # long enough for every thread to need it
      json(200, ME)
    end
    nohead, transport = client([me], project_id: nil)
    Array.new(5) { Thread.new { nohead.collections.list } }.each(&:join)
    assert_equal(1, transport.requests.count { |request| request.path == "/v1/me" })
  end

  def test_with_options_is_a_copy_with_other_settings
    events = []
    nohead, transport = client([api_error(500, "internal_error")], headers: { "X-A" => "1" })
    sent = -> { transport.requests.map { |request| [request.timeout, *request.headers.values_at("x-a", "X-B")] } }
    copy = nohead.with_options(timeout: 5, max_retries: 1, headers: { "x-a" => "2", "X-B" => "3" },
                               on_retry: ->(event) { events << event.attempt })
    assert_raises(Nohead::InternalServerError) { copy.records.get("rec_1") }
    assert_equal [[5, "2", "3"]] * 2, sent.call
    assert_equal [1], events

    transport.requests.clear
    assert_raises(Nohead::InternalServerError) { nohead.records.get("rec_1") }
    assert_equal [[60, nil, nil]] * 3, sent.call
    assert_equal(["1"] * 3, transport.requests.map { |request| request.headers["X-A"] })
    assert_equal [1], events
  end

  def test_with_options_shares_the_project_lookup
    nohead, transport = client([json(200, ME), page([])], project_id: nil)
    copy = nohead.with_options(timeout: 5)
    copy.collections.list
    nohead.collections.list
    nohead.with_options.webhooks.list
    assert_equal ["/v1/me", "/v1/projects/prj_9/collections", "/v1/projects/prj_9/collections",
                  "/v1/projects/prj_9/webhooks"], transport.requests.map(&:path)
  end

  def test_without_a_project_key
    user = { id: "usr_1", email: "ada@example.com", name: "Ada", staff: false }
    me = { object: "principal", type: "user", user: user, api_key: nil }
    nohead, = client([json(200, me)], project_id: nil)
    error = assert_raises(Nohead::Error) { nohead.collections.list }
    assert_match(/not a project API key/, error.message)
  end

  def test_objects_read_like_the_api
    # brand_new: a property the contract does not have yet.
    nohead, = client([raw(json(200, record("rec_1", title: "Hi").merge(brand_new: 1)))])
    post = nohead.records.get("rec_1")
    assert_equal "Hi", post.data["title"]
    assert_equal "Hi", post.data.title
    assert_equal "Hi", post[:data][:title]
    assert_equal 1, post.brand_new
    assert_equal Time.utc(2026, 10, 2, 12), post.created_at
    assert_nil post.published_at
    assert_respond_to post, :revision
    refute_respond_to post, :nothing_like_it
  end

  def test_timestamps_are_times
    nohead, = client([json(200, record("rec_1").merge(deleted_at: "2026-10-03T12:00:00.000Z",
                                                      purge_after: "2026-11-02T12:00:00.000Z"))])
    post = nohead.records.get("rec_1")
    assert_equal Time.utc(2026, 10, 3, 12), post.deleted_at
    assert_equal Time.utc(2026, 11, 2, 12), post.purge_after
    assert_equal "2026-10-02T12:00:00.000Z", post.to_h["created_at"]

    nohead, = client([json(200, { status: "ok", version: "v1", time: "2026-10-02T12:00:00Z" })])
    assert_equal Time.utc(2026, 10, 2, 12), nohead.health.check.time
    change = Nohead::NoheadObject.wrap({ "object" => "scheduled_change", "at" => "2027-01-01T09:00:00Z" })
    assert_equal Time.utc(2027, 1, 1, 9), change.at
  end

  # A field's value, even one named like the API's timestamps, stays as it
  # comes; the resources expanded in it have their timestamps.
  def test_field_values_stay_as_they_come
    moment = "2026-10-02T12:00:00.000Z"
    author = record("rec_2", published_at: moment)
    nohead, = client([json(200, record("rec_1", launch_at: moment, published_at: moment,
                                                links: [{ at: moment }], author: author))])
    post = nohead.records.get("rec_1")
    assert_equal [moment] * 3, [post.data["launch_at"], post.data.published_at, post.data.links.first.at]
    assert_equal Time.utc(2026, 10, 2, 12), post.data.author.created_at
    assert_equal moment, post.data.author.data.published_at
  end
end
