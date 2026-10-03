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
    nohead.records.list("posts", filter: { status: "published", featured: true, views: 3,
                                           published_after: Time.utc(2026, 1, 1), skip: nil },
                                 sort: "-published_at", expand: %w[author tags], limit: 50)
    params = transport.requests.first.params
    assert_equal "published", params["filter[status]"]
    assert_equal "true", params["filter[featured]"]
    assert_equal "3", params["filter[views]"]
    assert_equal "2026-01-01T00:00:00.000Z", params["filter[published_after]"]
    refute params.key?("filter[skip]")
    assert_equal "-published_at", params["sort"]
    assert_equal "author,tags", params["expand"]
    assert_equal "50", params["limit"]
    refute params.key?("cursor")
  end

  def test_sends_bodies_as_json
    nohead, transport = client([json(201, record("rec_1"))])
    assert_equal "rec_1", nohead.records.create("posts", data: { title: "Hi" }).id
    request = transport.requests.first
    assert_equal "POST", request.method
    assert_equal "application/json", request.headers["Content-Type"]
    assert_equal({ "data" => { "title" => "Hi" } }, request.json)
  end

  def test_serializes_times_in_bodies
    nohead, transport = client([json(200, record("rec_1"))])
    nohead.records.schedule("rec_1", publish_at: Time.utc(2027, 1, 1, 9))
    assert_equal({ "publish_at" => "2027-01-01T09:00:00.000Z" }, transport.requests.first.json)
  end

  def test_clears_scheduled_times
    nohead, transport = client([json(200, record("rec_1"))])
    nohead.records.schedule("rec_1", clear: [:unpublish_at])
    assert_equal({ "unpublish_at" => nil }, transport.requests.first.json)
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

  def test_dry_runs_are_query_parameters
    nohead, transport = client([json(200, {})])
    nohead.fields.migrate("fld_1", type: "integer", dry_run: true)
    assert_equal "true", transport.requests.first.params["dry_run"]
    assert_equal({ "type" => "integer" }, transport.requests.first.json)
  end

  def test_diff_names_its_revisions
    nohead, transport = client([json(200, { object: "record_diff", from: 1, to: 2, changes: [] })])
    diff = nohead.records.diff("rec_1", 1, 2)
    assert_equal [1, 2], [diff.from, diff.to]
    assert_equal({ "from" => "1", "to" => "2" }, transport.requests.first.params)
  end
end
