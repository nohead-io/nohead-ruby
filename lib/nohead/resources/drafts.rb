# frozen_string_literal: true

module Nohead
  module Resources
    # Drafts: changes to a record's content that wait until they are merged
    # into it, now or at a set time, while the record keeps its current
    # content. A record has at most one. `draft` is a draft ID ("drf_..."),
    # `record` a record ID and `collection` a collection ID or slug.
    class Drafts < Resource
      # Starts the record's draft: `data` over the record's values, or with
      # `from_revision`, over an earlier revision's. A second draft raises
      # ConflictError (detail code `draft_exists`, with its `draft_id`).
      def create(record, data: {}, from_revision: nil, idempotency_key: nil)
        @client.request("drafts_create", path: { record_id: record },
                                         body: { data: data, from_revision: from_revision }.compact,
                                         idempotency_key: idempotency_key)
      end

      # A collection's drafts, most recently changed first. `record_id`
      # narrows them to one record, or to several (an Array of 1 to 100; an
      # empty one raises ArgumentError, since it would match no record).
      def list(collection, record_id: nil, sort: nil, limit: nil, cursor: nil)
        raise ArgumentError, "record_id needs at least one record ID" if record_id == []

        record_filter = record_id.is_a?(Array) ? { in: record_id } : record_id
        @client.paginate("drafts_list", path: { collection_id: collection },
                                        query: { filter: { record_id: record_filter }, sort: sort,
                                                 limit: limit, cursor: cursor })
      end

      # With `data` as the record reads after the merge, for previews.
      def get(draft, expand: nil)
        @client.request("drafts_get", path: { draft_id: draft }, query: { expand: expand })
      end

      # Sets the given fields (nil clears one), as a record update does.
      def update(draft, data:, if_match: nil, idempotency_key: nil)
        @client.request("drafts_update", path: { draft_id: draft }, body: { data: data },
                                         if_match: if_match, idempotency_key: idempotency_key)
      end

      # Deletes the draft for good; returns it as it was.
      def discard(draft, if_match: nil, idempotency_key: nil)
        @client.request("drafts_discard", path: { draft_id: draft }, if_match: if_match,
                                          idempotency_key: idempotency_key)
      end

      # Applies the draft to its record now, as one `merge` revision, and
      # returns the record. Content only: the record stays live or not.
      def merge(draft, if_match: nil, idempotency_key: nil, change_note: nil)
        @client.request("drafts_merge", path: { draft_id: draft }, if_match: if_match,
                                        idempotency_key: idempotency_key, change_note: change_note)
      end

      # Merges the draft at `merge_at` (a Time or ISO 8601 string in the
      # future); returns the draft.
      def schedule(draft, merge_at:, idempotency_key: nil)
        @client.request("drafts_schedule", path: { draft_id: draft }, body: { merge_at: merge_at },
                                           idempotency_key: idempotency_key)
      end

      def unschedule(draft, idempotency_key: nil)
        @client.request("drafts_unschedule", path: { draft_id: draft }, idempotency_key: idempotency_key)
      end
    end
  end
end
