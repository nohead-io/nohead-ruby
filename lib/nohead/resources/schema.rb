# frozen_string_literal: true

module Nohead
  module Resources
    # Collections of the key's project. `collection` is an ID or slug.
    class Collections < Resource
      attr_reader :schema_changes, :search_index

      def initialize(client)
        super
        @schema_changes = SchemaChanges.new(client)
        @search_index = SearchIndexes.new(client)
      end

      # deleted: true lists deleted collections instead (restorable for 30 days).
      def list(deleted: nil, limit: nil, cursor: nil)
        @client.paginate("collections_list", query: { deleted: deleted, limit: limit, cursor: cursor })
      end

      def get(collection)
        @client.request("collections_get", path: { collection_id: collection })
      end

      # Creates a collection, optionally with its fields.
      def create(idempotency_key: nil, change_note: nil, **params)
        @client.request("collections_create", body: params, idempotency_key: idempotency_key,
                                              change_note: change_note)
      end

      def update(collection, idempotency_key: nil, change_note: nil, **params)
        @client.request("collections_update", path: { collection_id: collection }, body: params,
                                              idempotency_key: idempotency_key, change_note: change_note)
      end

      # Soft-deletes the collection and its records for 30 days.
      def delete(collection, idempotency_key: nil, change_note: nil)
        @client.request("collections_delete", path: { collection_id: collection },
                                              idempotency_key: idempotency_key, change_note: change_note)
      end

      def restore(collection, idempotency_key: nil, change_note: nil)
        @client.request("collections_restore", path: { collection_id: collection },
                                               idempotency_key: idempotency_key, change_note: change_note)
      end

      # The collection's schema, now or at a past `version`.
      def schema(collection, version: nil)
        @client.request("collections_get_schema", path: { collection_id: collection },
                                                  query: { version: version })
      end
    end

    # A collection's schema history, newest first.
    class SchemaChanges < Resource
      def list(collection, limit: nil, cursor: nil)
        @client.paginate("schema_changes_list", path: { collection_id: collection },
                                                query: { limit: limit, cursor: cursor })
      end

      def get(collection, schema_change)
        @client.request("schema_changes_get",
                        path: { collection_id: collection, schema_change_id: schema_change })
      end
    end

    # A collection's search index.
    class SearchIndexes < Resource
      def get(collection)
        @client.request("search_index_get", path: { collection_id: collection })
      end

      # Rebuilds the index from the records; searches keep working meanwhile.
      def rebuild(collection, idempotency_key: nil)
        @client.request("search_index_rebuild", path: { collection_id: collection },
                                                idempotency_key: idempotency_key)
      end
    end

    # Fields of a collection. `field` is a field ID ("fld_...").
    class Fields < Resource
      def list(collection, deleted: nil, limit: nil, cursor: nil)
        @client.paginate("fields_list", path: { collection_id: collection },
                                        query: { deleted: deleted, limit: limit, cursor: cursor })
      end

      def create(collection, idempotency_key: nil, change_note: nil, **params)
        @client.request("fields_create", path: { collection_id: collection }, body: params,
                                         idempotency_key: idempotency_key, change_note: change_note)
      end

      # Renames, describes or loosens a field. Changes that rewrite record
      # values (type, multiple, tighter rules) are `migrate`.
      def update(field, idempotency_key: nil, change_note: nil, **params)
        @client.request("fields_update", path: { field_id: field }, body: params,
                                         idempotency_key: idempotency_key, change_note: change_note)
      end

      # Soft-deletes the field: its values return with `restore` for 30 days.
      def delete(field, idempotency_key: nil, change_note: nil)
        @client.request("fields_delete", path: { field_id: field },
                                         idempotency_key: idempotency_key, change_note: change_note)
      end

      def restore(field, idempotency_key: nil, change_note: nil)
        @client.request("fields_restore", path: { field_id: field },
                                          idempotency_key: idempotency_key, change_note: change_note)
      end

      # Puts the collection's fields in this order.
      def reorder(collection, field_ids, idempotency_key: nil, change_note: nil)
        @client.request("fields_reorder", path: { collection_id: collection },
                                          body: { field_ids: field_ids },
                                          idempotency_key: idempotency_key, change_note: change_note)
      end

      # Stops accepting a renamed field's old API key before its 6 months end.
      def remove_alias(field, alias_key, idempotency_key: nil)
        @client.request("fields_remove_alias", path: { field_id: field, alias: alias_key },
                                               idempotency_key: idempotency_key)
      end

      # Starts a field migration (type, multiple, tighter configuration or a
      # backfill) that rewrites every record. With dry_run: true, previews it.
      def migrate(field, dry_run: false, idempotency_key: nil, change_note: nil, **params)
        @client.request("fields_migrate", path: { field_id: field }, query: { dry_run: dry_run || nil },
                                          body: params, idempotency_key: idempotency_key,
                                          change_note: change_note)
      end
    end

    # Field migrations. While one runs, its collection is read-only.
    class Migrations < Resource
      def list(collection, limit: nil, cursor: nil)
        @client.paginate("migrations_list", path: { collection_id: collection },
                                            query: { limit: limit, cursor: cursor })
      end

      def get(migration)
        @client.request("migrations_get", path: { migration_id: migration })
      end

      def cancel(migration, idempotency_key: nil)
        @client.request("migrations_cancel", path: { migration_id: migration },
                                             idempotency_key: idempotency_key)
      end
    end
  end
end
