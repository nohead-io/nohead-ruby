# frozen_string_literal: true

module Nohead
  module Resources
    # The base of the resources: each holds the client it sends requests with.
    class Resource
      def initialize(client)
        @client = client
      end

      def inspect = "#<#{self.class.name}>"
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
      # equality filters ({ status: "published" }), `expand` relation or asset
      # fields to embed under `expanded` (at most 5).
      def list(collection, filter: nil, sort: nil, expand: nil, limit: nil, cursor: nil)
        @client.paginate("records_list", path: { collection_id: collection }, query: {
                           filter: filter, sort: sort, expand: expand, limit: limit, cursor: cursor
                         })
      end

      def get(record, expand: nil, include_deleted: nil)
        @client.request("records_get", path: { record_id: record },
                                       query: { expand: expand, include_deleted: include_deleted })
      end

      # Creates a draft: create("posts", data: { title: "Hello" }).
      def create(collection, idempotency_key: nil, change_note: nil, **params)
        @client.request("records_create", path: { collection_id: collection }, body: params,
                                          idempotency_key: idempotency_key, change_note: change_note)
      end

      # Sets the given fields (nil clears one); others keep their values.
      def update(record, if_match: nil, idempotency_key: nil, change_note: nil, **params)
        @client.request("records_update", path: { record_id: record }, body: params,
                                          if_match: if_match, idempotency_key: idempotency_key,
                                          change_note: change_note)
      end

      # Soft-deletes the record: restore brings it back within 30 days.
      def delete(record, if_match: nil, idempotency_key: nil, change_note: nil)
        @client.request("records_delete", path: { record_id: record }, if_match: if_match,
                                          idempotency_key: idempotency_key, change_note: change_note)
      end

      def restore(record, idempotency_key: nil, change_note: nil)
        @client.request("records_restore", path: { record_id: record },
                                           idempotency_key: idempotency_key, change_note: change_note)
      end

      def publish(record, if_match: nil, idempotency_key: nil, change_note: nil)
        @client.request("records_publish", path: { record_id: record }, if_match: if_match,
                                           idempotency_key: idempotency_key, change_note: change_note)
      end

      def unpublish(record, if_match: nil, idempotency_key: nil, change_note: nil)
        @client.request("records_unpublish", path: { record_id: record }, if_match: if_match,
                                             idempotency_key: idempotency_key, change_note: change_note)
      end

      # Publishes and/or unpublishes the record later. Times left out keep
      # their value; name them in `clear` to remove them.
      def schedule(record, publish_at: nil, unpublish_at: nil, clear: [], idempotency_key: nil)
        body = clear.to_h { |name| [name.to_s, nil] }
        body["publish_at"] = publish_at unless publish_at.nil?
        body["unpublish_at"] = unpublish_at unless unpublish_at.nil?
        @client.request("records_schedule", path: { record_id: record }, body: body,
                                            idempotency_key: idempotency_key)
      end

      # Clears both scheduled times.
      def unschedule(record, idempotency_key: nil)
        @client.request("records_unschedule", path: { record_id: record },
                                              idempotency_key: idempotency_key)
      end

      def count(collection, filter: nil)
        @client.request("records_count", path: { collection_id: collection },
                                         query: { filter: filter })
      end

      # Publishes, unpublishes, deletes, restores or updates up to 100 records.
      # Each record succeeds or fails on its own; see `results`.
      def bulk(collection, idempotency_key: nil, change_note: nil, **params)
        @client.request("records_bulk", path: { collection_id: collection }, body: params,
                                        idempotency_key: idempotency_key, change_note: change_note)
      end

      # The changes between two revisions.
      def diff(record, from_revision, to_revision)
        @client.request("records_diff", path: { record_id: record },
                                        query: { from: from_revision, to: to_revision })
      end

      # Full-text search in one collection (search_enabled collections), most
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
      # Newest first. `filter` takes operation, actor_id, since and until.
      def list(record, filter: nil, limit: nil, cursor: nil)
        @client.paginate("record_revisions_list", path: { record_id: record },
                                                  query: { filter: filter, limit: limit, cursor: cursor })
      end

      def get(record, revision)
        @client.request("record_revisions_get", path: { record_id: record, revision: revision })
      end

      # Restores the record's data as of `revision`, as a new revision. With
      # dry_run: true, previews it.
      def revert(record, revision, dry_run: false, if_match: nil, idempotency_key: nil)
        @client.request("record_revisions_revert", path: { record_id: record, revision: revision },
                                                   query: { dry_run: dry_run || nil },
                                                   if_match: if_match, idempotency_key: idempotency_key)
      end
    end
  end
end
