# frozen_string_literal: true

require_relative "test_helper"

class PaginationTest < Minitest::Test
  include Helpers

  def test_returns_the_first_page
    nohead, transport = client([page([record("rec_1")], "c2")])
    first = nohead.records.list("posts", limit: 1)
    assert_instance_of Nohead::Page, first
    assert_equal ["rec_1"], first.data.map(&:id)
    assert_equal "c2", first.meta.next_cursor
    assert_predicate first, :next_page?
    refute transport.requests.first.params.key?("cursor")
  end

  def test_each_walks_every_page_keeping_the_parameters
    nohead, transport = client([page([record("rec_1"), record("rec_2")], "c2"), page([record("rec_3")], nil)])
    ids = nohead.records.list("posts", filter: { status: "draft" }).map(&:id)
    assert_equal %w[rec_1 rec_2 rec_3], ids
    assert_equal "c2", transport.requests[1].params["cursor"]
    assert_equal "draft", transport.requests[1].params["filter[status]"]
  end

  def test_stops_fetching_once_it_has_enough
    nohead, transport = client([page([record("rec_1"), record("rec_2")], "c2")])
    assert_equal ["rec_1"], nohead.records.list("posts").first(1).map(&:id)
    assert_equal 1, transport.requests.size
  end

  def test_pages_by_hand
    nohead, = client([page([record("rec_1")], "c2"), page([record("rec_2")], nil)])
    second = nohead.records.list("posts").next_page
    assert_equal "rec_2", second.data.first.id
    refute_predicate second, :next_page?
    assert_raises(Nohead::Error) { second.next_page }
  end

  def test_resumes_from_a_cursor
    nohead, transport = client([page([], nil)])
    nohead.records.list("posts", cursor: "saved")
    assert_equal "saved", transport.requests.first.params["cursor"]
  end

  def test_search_totals
    nohead, transport = client([page([record("r")], nil, total_estimate: 1)])
    hits = nohead.search("hello", collections: %w[posts pages])
    assert_equal 1, hits.meta.total_estimate
    assert_equal "/v1/projects/prj_1/search", transport.requests.first.path
    assert_equal "posts,pages", transport.requests.first.params["collections"]
  end
end
