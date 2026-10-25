# frozen_string_literal: true

require_relative "test_helper"

class RequestsTest < Minitest::Test
  include Helpers

  def test_encodes_path_parameters
    nohead, transport = client([page([], nil)])
    nohead.records.list("my posts/1")
    assert_equal "https://api.test/v1/collections/my%20posts%2F1/records", transport.requests.first.url
  end

  def test_serializes_filters_sorts_and_expansions
    nohead, transport = client([page([], nil)])
    nohead.records.list("posts", filter: { category: "news", featured: true, views: 3,
                                           published_after: Time.utc(2026, 1, 1), skip: nil },
                                 sort: "-published_at", expand: %w[author tags], limit: 50)
    params = transport.requests.first.params
    assert_equal "news", params["filter[category]"]
    assert_equal "true", params["filter[featured]"]
    assert_equal "3", params["filter[views]"]
    assert_equal "2026-01-01T00:00:00.000Z", params["filter[published_after]"]
    refute params.key?("filter[skip]")
    assert_equal "-published_at", params["sort"]
    assert_equal "author,tags", params["expand"]
    assert_equal "50", params["limit"]
    refute params.key?("cursor")
  end

  def test_serializes_filter_operators_escaping_commas_in_lists
    nohead, transport = client([page([], nil)])
    nohead.records.list("products", filter: { brand: { ne: "acme" }, price: { gte: 10, lt: 50 },
                                              category: { in: ["shoes", "hats, caps", "a\\b"] },
                                              cover: { exists: true }, released: { gte: Date.new(2026, 10, 9) } },
                                    sort: "-price")
    params = transport.requests.first.params
    assert_equal "acme", params["filter[brand][ne]"]
    assert_equal "10", params["filter[price][gte]"]
    assert_equal "50", params["filter[price][lt]"]
    assert_equal "shoes,hats\\, caps,a\\\\b", params["filter[category][in]"]
    assert_equal "true", params["filter[cover][exists]"]
    assert_equal "2026-10-09", params["filter[released][gte]"]
    assert_equal "-price", params["sort"]
  end

  def test_sends_bodies_as_json
    nohead, transport = client([json(201, record("rec_1"))])
    assert_equal "rec_1", nohead.records.create("posts", data: { title: "Hi" }).id
    request = transport.requests.first
    assert_equal "POST", request.method
    assert_equal "application/json", request.headers["Content-Type"]
    assert_equal({ "data" => { "title" => "Hi" } }, request.json)
  end

  SCHEDULE = { object: "schedule", record_id: "rec_1", publish_at: nil, unpublish_at: nil, last_error: nil }.freeze

  def test_serializes_times_in_bodies
    nohead, transport = client([json(200, SCHEDULE)])
    nohead.records.schedule("rec_1", publish_at: Time.utc(2027, 1, 1, 9))
    assert_equal({ "publish_at" => "2027-01-01T09:00:00.000Z" }, transport.requests.first.json)
  end

  def test_schedule_sends_the_whole_schedule
    nohead, transport = client([json(200, SCHEDULE)])
    nohead.records.schedule("rec_1", unpublish_at: "2027-02-01T00:00:00Z")
    nohead.records.schedule("rec_1")
    assert_equal([{ "unpublish_at" => "2027-02-01T00:00:00Z" }, {}], transport.requests.map(&:json))
  end

  def test_idempotency_keys_on_writes_only
    nohead, transport = client([json(200, record("rec_1"))])
    nohead.records.publish("rec_1")
    nohead.records.publish("rec_1")
    nohead.records.get("rec_1")
    keys = transport.requests.map { |request| request.headers["Idempotency-Key"] }
    assert_match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/, keys[0])
    refute_equal keys[0], keys[1]
    assert_nil keys[2]
  end

  def test_the_callers_idempotency_key
    nohead, transport = client([json(201, record("rec_1"))])
    nohead.records.create("posts", data: {}, idempotency_key: "import-42")
    assert_equal "import-42", transport.requests.first.headers["Idempotency-Key"]
  end

  def test_if_match_from_a_revision_or_a_record
    nohead, transport = client([json(200, record("rec_1"))])
    post = nohead.records.update("rec_1", data: { title: nil }, if_match: 3)
    nohead.records.publish("rec_1", if_match: post)
    assert_equal(['"3"', '"1"'], transport.requests.map { |request| request.headers["If-Match"] })
  end

  def test_change_note
    nohead, transport = client([json(200, record("rec_1"))])
    nohead.records.delete("rec_1", change_note: "Duplicate")
    assert_equal "Duplicate", transport.requests.first.headers["Nohead-Change-Note"]
  end

  def test_change_note_in_any_language_percent_encoded
    nohead, transport = client([json(200, record("rec_1"))])
    nohead.records.delete("rec_1", change_note: "Rettet på forsiden ✓")
    assert_equal "Rettet%20p%C3%A5%20forsiden%20%E2%9C%93", transport.requests.first.headers["Nohead-Change-Note"]
  end

  def test_change_note_in_another_encoding_is_sent_as_utf8
    nohead, transport = client([json(200, record("rec_1"))])
    nohead.records.delete("rec_1", change_note: "Bl\xE5b\xE6r".dup.force_encoding(Encoding::ISO_8859_1))
    assert_equal "Bl%C3%A5b%C3%A6r", transport.requests.first.headers["Nohead-Change-Note"]
  end

  def test_dry_runs_are_query_parameters
    nohead, transport = client([json(200, example("migrations_create"))])
    nohead.migrations.create("posts", field_id: "fld_1", type: "integer", dry_run: true)
    assert_equal "/v1/collections/posts/migrations", transport.requests.first.path
    assert_equal "true", transport.requests.first.params["dry_run"]
    assert_equal({ "field_id" => "fld_1", "type" => "integer" }, transport.requests.first.json)
  end

  def test_diff_names_its_revisions
    nohead, transport = client([json(200, { object: "record_diff", record_id: "rec_1", from: 1, to: 2, changes: [] })])
    nohead.records.diff("rec_1", from: 1, to: 2)
    assert_equal({ "from" => "1", "to" => "2" }, transport.requests.first.params)
  end

  def test_options_a_method_does_not_take_are_not_sent_as_body_fields
    nohead, transport = client([json(201, {})])
    [
      -> { nohead.webhooks.create(url: "https://example.com/hook", event_types: ["*"], change_note: "New") },
      -> { nohead.webhooks.update("wh_1", enabled: false, change_note: "Off") },
      -> { nohead.assets.create_upload(filename: "a.txt", content_type: "text/plain", byte_size: 1, change_note: "x") },
      -> { nohead.records.bulk("posts", action: "publish", record_ids: [], if_match: 1) },
      -> { nohead.collections.update("posts", name: "Articles", if_match: 1) }
    ].each do |call|
      error = assert_raises(ArgumentError, &call)
      assert_match(/unknown keyword: :(change_note|if_match)/, error.message)
    end
    assert_empty transport.requests
  end

  def test_audit_event_filters
    nohead, transport = client([page([], nil)])
    nohead.audit_events.list(filter: { type: "record.*", resource_type: %w[record draft], actor_type: "api_key",
                                       created_at: { gte: Time.utc(2026, 10, 1), lt: "2026-11-01T00:00:00Z" } })
    nohead.audit_events.list(filter: { "resource_type" => "field" })
    first, second = transport.requests.map(&:params)
    assert_equal({ "filter[type]" => "record.*", "filter[resource_type][in]" => "record,draft",
                   "filter[actor_type]" => "api_key", "filter[created_at][gte]" => "2026-10-01T00:00:00.000Z",
                   "filter[created_at][lt]" => "2026-11-01T00:00:00Z" }, first)
    assert_equal({ "filter[resource_type]" => "field" }, second)
  end

  def test_revision_filters
    nohead, transport = client([page([], nil)])
    nohead.records.revisions.list("rec_1", filter: { operation: "merge", created_at: { gt: Time.utc(2026, 10, 1) } })
    assert_equal({ "filter[operation]" => "merge", "filter[created_at][gt]" => "2026-10-01T00:00:00.000Z" },
                 transport.requests.first.params)
  end

  def test_restore_and_revert_take_if_match_and_a_change_note
    nohead, transport = client([json(200, record("rec_1"))])
    nohead.records.restore("rec_1", if_match: 4, change_note: "Back")
    nohead.records.revisions.revert("rec_1", 2, if_match: 5, change_note: "Undo")
    assert_equal([['"4"', "Back"], ['"5"', "Undo"]],
                 transport.requests.map { |request| request.headers.values_at("If-Match", "Nohead-Change-Note") })
  end
end
