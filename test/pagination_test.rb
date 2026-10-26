# frozen_string_literal: true

require_relative "test_helper"

class PaginationTest < Minitest::Test
  include Helpers

  def test_returns_the_first_page_then_pages_by_hand
    nohead, transport = client([page([record("rec_1")], next_cursor: "c2", has_more: true),
                                page([record("rec_2")])])
    first = nohead.records.list("posts", limit: 1)
    assert_instance_of Nohead::Page, first
    assert_equal ["rec_1"], first.data.map(&:id)
    assert_equal "c2", first.meta.next_cursor
    assert_predicate first, :next_page?
    refute transport.requests.first.params.key?("cursor")
    second = first.next_page
    assert_equal "rec_2", second.data.first.id
    assert_equal "c2", transport.requests[1].params["cursor"]
    refute_predicate second, :next_page?
    assert_raises(Nohead::Error) { second.next_page }
  end

  def test_each_walks_every_page_keeping_the_parameters
    nohead, transport = client([page([record("rec_1"), record("rec_2")], next_cursor: "c2", has_more: true),
                                page([record("rec_3")])])
    ids = nohead.records.list("posts", filter: { featured: true }).map(&:id)
    assert_equal %w[rec_1 rec_2 rec_3], ids
    assert_equal "c2", transport.requests[1].params["cursor"]
    assert_equal "true", transport.requests[1].params["filter[featured]"]
  end

  def test_stops_fetching_once_it_has_enough
    nohead, transport = client([page([record("rec_1"), record("rec_2")], next_cursor: "c2", has_more: true)])
    assert_equal ["rec_1"], nohead.records.list("posts").first(1).map(&:id)
    assert_equal 1, transport.requests.size
  end

  def test_stops_when_has_more_is_false
    nohead, transport = client([page([record("rec_1")], next_cursor: "c2", has_more: false)])
    page = nohead.records.list("posts")
    refute_predicate page, :next_page?
    assert_equal ["rec_1"], page.map(&:id)
    assert_equal 1, transport.requests.size
  end

  def test_stops_on_has_more_without_a_cursor
    nohead, transport = client([page([record("rec_1")], has_more: true)])
    page = nohead.records.list("posts")
    refute_predicate page, :next_page?
    assert_equal ["rec_1"], page.map(&:id)
    assert_equal 1, transport.requests.size
  end

  def test_walks_past_an_empty_page
    nohead, transport = client([page([], next_cursor: "c2", has_more: true), page([record("rec_2")])])
    assert_equal ["rec_2"], nohead.records.list("posts").map(&:id)
    assert_equal([nil, "c2"], transport.requests.map { |request| request.params["cursor"] })
  end

  def test_resumes_from_a_cursor
    nohead, transport = client([page([])])
    nohead.records.list("posts", cursor: "saved")
    assert_equal "saved", transport.requests.first.params["cursor"]
  end

  def test_searches_assets_and_lists_them_by_kind
    nohead, transport = client([page([]), page([])])
    nohead.assets.list(q: "hero jpg", kind: "image").data
    nohead.assets.list(kind: %w[image video]).data
    assert_equal({ "q" => "hero jpg", "filter[kind]" => "image" }, transport.requests[0].params)
    assert_equal({ "filter[kind][in]" => "image,video" }, transport.requests[1].params)
  end

  def test_lists_assets_by_content_type
    nohead, transport = client([page([]), page([]), page([])])
    nohead.assets.list(content_type: "image/*").data
    nohead.assets.list(content_type: %w[image/* application/pdf]).data
    nohead.assets.list(content_type: []).data
    assert_equal "image/*", transport.requests[0].params["filter[content_type]"]
    assert_equal "image/*,application/pdf", transport.requests[1].params["filter[content_type][in]"]
    # An empty list, like an asset field's accepted_types, is any type.
    assert_empty transport.requests[2].params.keys.grep(/content_type/)
  end

  def test_a_list_response_that_is_not_a_page
    [json(200, [1]), Nohead::Response.new(200, { "content-type" => "text/html" }, "<html>Hi</html>"),
     json(200, { data: nil, meta: {} }), json(200, { data: [] })].each do |reply|
      nohead, = client([raw(reply)])
      error = assert_raises(Nohead::Error) { nohead.records.list("posts") }
      assert_equal "The API's response could not be read (HTTP 200)", error.message
    end
  end

  def test_search_totals
    nohead, transport = client([page([record("r")], total_estimate: 1)])
    hits = nohead.search("hello", collections: %w[posts pages], filter: { published_at: { exists: true } })
    assert_equal 1, hits.meta.total_estimate
    assert_equal "/v1/projects/prj_1/search", transport.requests.first.path
    assert_equal "posts,pages", transport.requests.first.params["filter[collection][in]"]
    assert_equal "true", transport.requests.first.params["filter[published_at][exists]"]
  end

  def test_search_collections_win_over_a_collection_filter
    nohead, transport = client([page([], total_estimate: 0)])
    nohead.search("hello", collections: ["posts"], filter: { "collection" => "pages" }).data
    nohead.search("hello", filter: { collection: "pages" }).data
    first, second = transport.requests.map(&:params)
    assert_equal({ "q" => "hello", "filter[collection][in]" => "posts" }, first)
    assert_equal({ "q" => "hello", "filter[collection]" => "pages" }, second)
  end
end
