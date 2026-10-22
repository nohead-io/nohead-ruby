# frozen_string_literal: true

module Nohead
  module Resources
    # The base of the resources: each holds the client it sends requests with.
    class Resource
      # Request options that are headers, not body fields.
      OPTIONS = %i[change_note if_match].freeze

      def initialize(client)
        @client = client
      end

      def inspect = "#<#{self.class.name}>"

      private

      # The keyword arguments a method sends as the body. SDK options would
      # land there when the method doesn't take them (its operation doesn't
      # declare the header), so they raise ArgumentError as Ruby does for
      # unknown keywords.
      def body_of(params)
        option = OPTIONS.find { |name| params.key?(name) }
        raise ArgumentError, "unknown keyword: :#{option}" if option

        params
      end
    end

    # Records: the content of a collection. `collection` is a collection ID or
    # slug; `record` a record ID ("rec_...").
    class Records < Resource
      attr_reader :revisions

      def initialize(client)
        super
        @revisions = Revisions.new(client)
      end

      # A collection's records, newest first by default. `filter` holds
      # filters ({ published_at: { exists: true } } for published records),
      # `expand` relation or asset fields to embed under `expanded` (at most 5).
      def list(collection, filter: nil, sort: nil, expand: nil, limit: nil, cursor: nil)
        @client.paginate("records_list", path: { collection_id: collection }, query: {
                           filter: filter, sort: sort, expand: expand, limit: limit, cursor: cursor
                         })
      end

      # A deleted record too, with `deleted_at` and `purge_after`.
      def get(record, expand: nil)
        @client.request("records_get", path: { record_id: record }, query: { expand: expand })
      end

      # Creates an unpublished record: create("posts", data: { title: "Hello" }).
      # With upsert_on:, the key of a unique field, it updates the record holding
      # that value instead, if one exists, so a sync can run again without
      # duplicates; if_match: then applies to that update.
      def create(collection, if_match: nil, idempotency_key: nil, change_note: nil, **params)
        @client.request("records_create", path: { collection_id: collection }, body: body_of(params),
                                          if_match: if_match, idempotency_key: idempotency_key,
                                          change_note: change_note)
      end

      # Sets the given fields (nil clears one); others keep their values.
      def update(record, if_match: nil, idempotency_key: nil, change_note: nil, **params)
        @client.request("records_update", path: { record_id: record }, body: body_of(params),
                                          if_match: if_match, idempotency_key: idempotency_key,
                                          change_note: change_note)
      end

      # Soft-deletes the record: restore brings it back until its `purge_after`.
      # Deleting a deleted record changes nothing.
      def delete(record, if_match: nil, idempotency_key: nil, change_note: nil)
        @client.request("records_delete", path: { record_id: record }, if_match: if_match,
                                          idempotency_key: idempotency_key, change_note: change_note)
      end

      def restore(record, if_match: nil, idempotency_key: nil, change_note: nil)
        @client.request("records_restore", path: { record_id: record }, if_match: if_match,
                                           idempotency_key: idempotency_key, change_note: change_note)
      end

      # A live record with a pending draft raises ConflictError (detail code
      # `draft_pending`): publishing never merges a draft (drafts.merge does).
      def publish(record, if_match: nil, idempotency_key: nil, change_note: nil)
        @client.request("records_publish", path: { record_id: record }, if_match: if_match,
                                           idempotency_key: idempotency_key, change_note: change_note)
      end

      def unpublish(record, if_match: nil, idempotency_key: nil, change_note: nil)
        @client.request("records_unpublish", path: { record_id: record }, if_match: if_match,
                                             idempotency_key: idempotency_key, change_note: change_note)
      end

      # What is live: since when, by whom, and the revision. Raises
      # NotFoundError (detail code `not_published`) for a record that isn't
      # published.
      def publication(record)
        @client.request("records_get_publication", path: { record_id: record })
      end

      # When the record publishes or unpublishes on its own. Raises
      # NotFoundError (detail code `not_scheduled`) for a record with no
      # schedule.
      def get_schedule(record)
        @client.request("records_get_schedule", path: { record_id: record })
      end

      # Sets when the record publishes and/or unpublishes on its own, and
      # returns the schedule. It replaces the whole schedule: a time left out
      # is cleared (schedule(record, publish_at: t) drops a set unpublish_at).
      def schedule(record, publish_at: nil, unpublish_at: nil, idempotency_key: nil)
        @client.request("records_schedule", path: { record_id: record },
                                            body: { publish_at: publish_at, unpublish_at: unpublish_at }.compact,
                                            idempotency_key: idempotency_key)
      end

      # Clears both scheduled times.
      def unschedule(record, idempotency_key: nil)
        @client.request("records_unschedule", path: { record_id: record },
                                              idempotency_key: idempotency_key)
      end

      # The record's drafts: at most one for now.
      def drafts(record, limit: nil, cursor: nil)
        @client.paginate("record_drafts_list", path: { record_id: record }, query: { limit: limit, cursor: cursor })
      end

      # A collection's pending scheduled changes, soonest first: publishes,
      # unpublishes and draft merges, one per change, so a record due to
      # publish and later unpublish appears twice.
      def scheduled_changes(collection, sort: nil, limit: nil, cursor: nil)
        @client.paginate("scheduled_changes_list", path: { collection_id: collection },
                                                   query: { sort: sort, limit: limit, cursor: cursor })
      end

      def count(collection, filter: nil)
        @client.request("records_count", path: { collection_id: collection },
                                         query: { filter: filter })
      end

      # Publishes, unpublishes, deletes, restores or updates up to 100 records.
      # Each record succeeds or fails on its own; see `results`.
      def bulk(collection, idempotency_key: nil, change_note: nil, **params)
        @client.request("records_bulk", path: { collection_id: collection }, body: body_of(params),
                                        idempotency_key: idempotency_key, change_note: change_note)
      end

      # The changes between two revisions: diff(record, from: 1, to: 2).
      def diff(record, from:, to:)
        @client.request("records_diff", path: { record_id: record }, query: { from: from, to: to })
      end

      # Full-text search in one collection, matching its searchable fields, most
      # relevant first, through the first 1,000 hits.
      def search(collection, query, filter: nil, sort: nil, expand: nil, limit: nil, cursor: nil)
        @client.paginate("collections_search", path: { collection_id: collection }, query: {
                           q: query, filter: filter, sort: sort, expand: expand, limit: limit,
                           cursor: cursor
                         })
      end
    end

    # A record's version history. `revision` is a revision number.
    class Revisions < Resource
      # Newest first. `filter` takes `operation`, `actor_id` and a `created_at`
      # range ({ created_at: { gte: Time.utc(2026, 10, 1) } }).
      def list(record, filter: nil, limit: nil, cursor: nil)
        @client.paginate("record_revisions_list", path: { record_id: record },
                                                  query: { filter: filter, limit: limit, cursor: cursor })
      end

      def get(record, revision)
        @client.request("record_revisions_get", path: { record_id: record, revision: revision })
      end

      # Restores the record's data as of `revision`, as a new revision. With
      # dry_run: true, previews it.
      def revert(record, revision, dry_run: false, if_match: nil, idempotency_key: nil, change_note: nil)
        @client.request("record_revisions_revert", path: { record_id: record, revision: revision },
                                                   query: { dry_run: dry_run || nil }, if_match: if_match,
                                                   idempotency_key: idempotency_key, change_note: change_note)
      end
    end

    # A revision by its own ID ("rev_..."), as webhooks and the activity log name
    # it. Readable while its record is deleted.
    class RevisionsById < Resource
      def get(revision)
        @client.request("revisions_get", path: { revision_id: revision })
      end
    end
  end
end
