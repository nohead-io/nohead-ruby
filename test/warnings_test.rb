# frozen_string_literal: true

require_relative "test_helper"

class WarningsTest < Minitest::Test
  include Helpers

  SUNSET = "Fri, 01 Jan 2027 00:00:00 GMT"
  LINK = "https://nohead.io/docs/changelog"
  DEPRECATED = { "deprecation" => "@1790000000", "sunset" => SUNSET, "link" => %(<#{LINK}>; rel="deprecation") }.freeze
  OVER = { "nohead-usage-warning" => "records 1001/1000" }.freeze

  # Warnings are once per process: each test starts without any given.
  def setup = Nohead::Client::WARNED.clear

  # What a client with these replies warns, as lines, while the block uses it.
  def warnings(replies, **)
    nohead, = client(replies, **)
    _, err = capture_io { yield nohead }
    err.lines(chomp: true)
  end

  def test_warns_once_per_deprecated_operation
    lines = warnings([json(200, record("rec_1"), DEPRECATED)]) do |nohead|
      2.times { nohead.records.get("rec_1") }
      2.times { nohead.records.publish("rec_1") }
    end
    assert_equal(["[nohead] records_get is deprecated and will be removed after #{SUNSET}. See #{LINK}",
                  "[nohead] records_publish is deprecated and will be removed after #{SUNSET}. See #{LINK}"], lines)
  end

  def test_warns_once_per_process_across_clients
    first = warnings([json(200, record("rec_1"), DEPRECATED)]) { |nohead| nohead.records.get("rec_1") }
    second = warnings([json(200, record("rec_1"), DEPRECATED)]) { |nohead| nohead.records.get("rec_1") }
    assert_equal 1, first.size
    assert_empty second
  end

  def test_a_deprecation_without_sunset_or_link
    lines = warnings([json(200, record("rec_1"), { "deprecation" => "@1790000000" })]) do |nohead|
      nohead.records.get("rec_1")
    end
    assert_equal ["[nohead] records_get is deprecated"], lines
  end

  def test_an_empty_deprecation_header_is_no_deprecation
    lines = warnings([json(200, record("rec_1"), { "deprecation" => "" })]) do |nohead|
      nohead.records.get("rec_1")
    end
    assert_empty lines
  end

  def test_warns_once_about_usage
    lines = warnings([json(200, record("rec_1"), OVER)]) do |nohead|
      nohead.records.get("rec_1")
      nohead.records.publish("rec_1")
    end
    assert_equal ["[nohead] Over a plan limit: records 1001/1000"], lines
  end

  def test_silent_when_turned_off
    lines = warnings([json(200, record("rec_1"), DEPRECATED.merge(OVER))], warnings: false) do |nohead|
      nohead.records.get("rec_1")
    end
    assert_empty lines
  end
end
