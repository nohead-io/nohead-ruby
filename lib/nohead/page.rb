# frozen_string_literal: true

module Nohead
  # One page of a list. `each` (and so `map`, `first`, `to_a`...) walks every
  # item from here on, fetching later pages as needed:
  #
  #   nohead.records.list("posts").each { |record| puts record.data["title"] }
  #
  #   page = nohead.records.list("posts", limit: 100)
  #   page.data # this page's items
  #   page = page.next_page while page.next_page?
  class Page
    include Enumerable

    # The items on this page.
    attr_reader :data
    # `next_cursor` and `has_more` (and `total_estimate` for search).
    attr_reader :meta

    def initialize(data, meta, &fetch)
      @data = data
      @meta = meta
      @fetch = fetch
    end

    def next_page?
      meta["has_more"] == true && !meta["next_cursor"].nil?
    end

    # The next page; raises Nohead::Error when there is none.
    def next_page
      raise Error, "There is no next page" unless next_page?

      @fetch.call(meta["next_cursor"])
    end

    def each(&block)
      return enum_for(:each) unless block

      page = self
      loop do
        page.data.each(&block)
        break unless page.next_page?

        page = page.next_page
      end
      self
    end

    def inspect = "#<Nohead::Page #{data.size} items, more: #{next_page?}>"
  end
end
