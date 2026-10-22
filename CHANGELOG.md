# Changelog

Changes to the `nohead` gem that you can notice. Versions follow
[Semantic Versioning](https://semver.org): additive API changes are minor
releases; a change that could break your code is a major one. Each release's
section is its GitHub release's notes.

## Unreleased

- `assets.list(q:, kind:)`: `q` finds assets whose filename or alt text has
  every word, ignoring case; `kind` lists only `image`, `video`, `audio`,
  `document` or `other` assets, or several kinds as an array.

## 0.6.0

- API keys now start `nohead_sk_`, or `nohead_pk_` for published-only keys;
  keys in the old `sk_live_` format no longer work. The gem sends whatever key
  it's given, so only the docs and examples change.

- `assets.update(asset, filename:, alt:)` renames an asset and sets its alt
  text (`PATCH /v1/assets/{asset_id}`). Assets have `alt` (a string or
  `nil`), and webhooks can subscribe to `asset.updated`.

- Image URLs are open. Assets have `image_url`, the whole image, and the new
  `Nohead::Images.url` writes any of imgproxy's processing options into it,
  without a request.

- **Breaking:** `assets.image_url` is gone, with the API's
  `GET /v1/assets/{asset_id}/image-url`: use `Nohead::Images.url`, which
  needs no request.

- **Breaking:** collections have no `search_enabled`, and search indexes no
  `enabled`, and collections' `create` and `update` no longer take
  `search_enabled:`: API keys search every collection they can read.

- `revisions.get(revision)` reads a revision by its own `rev_` ID, as
  webhooks and the activity log name it (`GET /v1/revisions/{revision_id}`).

- `records.create` takes `upsert_on:`, a unique field's key: the record
  holding that value is updated instead, if one exists, and `if_match:`
  applies to that update.

- Collections have `public_search`: whether the project's search tokens find
  their published records. Off by default;
  `collections.create(public_search: ...)` and `collections.update` take it. A
  collection's search index has `index`, the name a token searches it by.

## 0.5.0

- **Breaking:** field migrations are created under their collection:
  `migrations.create(collection, field_id:, ..., dry_run: true)`
  (`POST /v1/collections/{collection_id}/migrations`) replaces
  `fields.migrate(field, ...)`. It returns a preview for a dry run, and the
  FieldMigration otherwise.
- **Breaking:** `drafts.list` no longer takes `record_id:`; a record's draft
  is `records.drafts(record)`.
- **Breaking:** `assets.list(content_type:)` takes one MIME type or `type/*`
  wildcard (`"image/*"`), or an Array of them, sent as
  `filter[content_type][in]` (an empty Array is any type). A
  comma-separated string is no longer several types.
- **Breaking:** `audit_events.list` sorts by `created_at` or `-created_at`
  (the default; was `id` and `-id`), and `records.list` no longer sorts by
  `id`.
- Webhook events always carry `actor` and `via`, and `via` is no longer
  `import` or `migration`.

## 0.4.0

- **Breaking:** a field's `api_key` is its `key` (in fields, their aliases,
  `fields.create(..., key:)` and `fields.update(..., key:)`), as the
  editor's "Field key" says. API keys keep their name.
- **Breaking:** `collections.schema_changes.get(schema_change)` takes the
  schema change's ID alone (`GET /v1/schema-changes/{id}`).
- **Breaking:** `fields.update` no longer takes `type` or `multiple`; they
  rewrite record values, so they are `fields.migrate`. The API refuses a
  body key an operation doesn't take with `400` (`unknown_parameter`,
  naming it), so a misspelt keyword no longer passes unnoticed.
- The contract types each field's `configuration` by field type; the API
  reference lists each type's options.

## 0.3.0

- **Upgrade required:** 0.1 and 0.2 no longer work with the current API,
  whose paths changed.
- `change_note` is sent percent-encoded (UTF-8), so change notes work in any
  language: a note outside ASCII used to fail the request.
- Drafts: changes to a record that wait until they are merged into it, now
  or at a set time. `drafts.create`, `list`, `get` (with `expand`, for
  previews), `update`, `discard`, `merge`, `schedule` and `unschedule`, and
  `records.drafts`. `records.publish` on a live record with a pending draft
  raises `ConflictError` (`draft_pending`). Webhook events of `draft.*` carry
  the `draft` and its `draft_id`, and a merge's `record.updated` its
  `draft_id`.
- **Breaking:** the API is resource-oriented. Method names stay; what they
  return and take follows it:
  - Records have no `status`, `schedule` or `deleted`: a record is published
    when `published_at` is set, and has `deleted_at` and `purge_after`.
    Filter with `{ published_at: { exists: true } }`. `records.get` returns
    deleted records too (no `include_deleted`).
  - `records.schedule` replaces the whole schedule: a time left out is
    cleared, and `clear:` is gone. It and `unschedule` return the schedule,
    and `records.get_schedule`, `records.publication` and
    `records.scheduled_changes` are new. A scheduled change has no
    `last_error`. `records.bulk` returns a record batch.
  - `search` takes `filter:` as `records.list` does
    (`filter: { published_at: { exists: true } }`) instead of
    `status: "published"`.
  - `records.diff(record, from:, to:)` and
    `fields.reorder(collection, field_ids:)` take keywords.
  - `audit_events.list` filters by `type` (was `action`), `resource_type`
    (a type, or an Array of them), `resource_id`, `actor_type`, `actor_id`
    and a `created_at` range (`{ gte: ..., lt: ... }`, was `since` and
    `until`); the API refuses other filters. Events have `object: "event"`
    and their name in `type`, and a field's events the resource type
    `field`.
  - `records.revisions.list` filters by a `created_at` range (was `since`
    and `until`), and a revision's `operation` can be `merge` (no
    `import`).
  - Schema changes have no `status`.
  - Collections, fields, assets and webhooks have `deleted_at` and
    `purge_after` instead of `deleted`, and migrations
    `cancel_requested_at`.
  - `assets.create_upload` returns the asset with its `upload`.
  - `fields.reorder` returns the field order; `fields.order` reads it.
  - Webhook event types are the same as the activity log's
    (`record.restored`, `field.updated`, ..., and wildcards such as
    `record.*`), and events carry
    `actor` and `via`. `webhooks.rotate_secret` returns the new webhook
    secret with its value; the old secret signs for 24 hours more.
    `webhooks.secrets.list`, `webhooks.secrets.retire`, `webhooks.restore`
    and `webhooks.list(deleted: true)` are new. There is no
    `record.imported` event; `field.*` events carry the `field_id`, and
    schema events' `collection` its `object`.
  - `if_match` and `change_note` go where the API takes them:
    `records.restore` takes `if_match` and `records.revisions.revert`
    `change_note`. Methods that take fields as keywords
    (`webhooks.create`, `assets.create_upload`...) raise ArgumentError for
    an `if_match` or `change_note` they don't take, instead of sending it
    as a field.
  - Timestamps are the ones the API declares, so `purge_after`, a
    scheduled change's `at` and `health.check`'s `time` are Times too, and
    a record's field values are left as they come (a field whose name
    ended in `_at` used to be a Time).
- **Breaking:** the `datetime` field type is now `date`. A plain date field holds
  `YYYY-MM-DD`; with `include_time` it holds a moment, written in the field's
  `time_zone` when it has one. Field migrations take `time_zone`, the zone
  whose day each moment falls on when the time is removed.
- Boolean fields can't be `required`: a boolean is true or false, and no
  value reads as false.
- Text fields take a `format` (`email`, `url`, `slug`; slugs are always
  unique) and text and integer fields `unique`; a taken value's error detail
  has the `record_id` that has it (`code: "taken"`).
- Filters take operators: `{ price: { lt: 50 } }`, with `eq`, `ne`, `gt`,
  `gte`, `lt`, `lte`, `in` (an array) and `exists`, and record lists sort by
  a field's value. Commas and backslashes in array values are escaped, so a
  value can hold a comma.
- Date filters take `today`, and dates with a time `now`.
- `assets.usage`: where an asset is used, as counts of the records that use
  it (and of those, the published ones) and the 10 most recently updated with
  the fields that use it. Needs the `records:read` scope too.
- `assets.purge`: permanently deletes a deleted asset now, instead of at its
  `purge_after`, and frees its storage.
- `fields.get`.
- `assets.upload` with an `idempotency_key` resumes: an asset that is
  already `ready` comes back without sending the bytes again, and one whose
  upload URL expired raises `UploadError` (start over with a new key).
- An error reads only the fields of the API's error envelope that have the
  right type, so JSON from a proxy or gateway that merely looks like one no
  longer gives it a non-string `message`, `type` or `request_id`, turns a
  `details` object into key-value pairs, or makes `current_revision` raise on
  a detail that isn't an object.

## 0.2.0

- Types follow the API's current contract. They add types only for
  operations an API key can't call, so no method changed.

## 0.1.0

The first release.

- `Nohead::Client`, with methods for every operation an API key can call:
  records (with revisions, scheduling, bulk changes and search),
  collections, fields and migrations, assets, webhooks and their deliveries,
  the audit log, feature flags.
- Results you read with methods or `[]`, pages that are Enumerable across
  every page, timestamps as Times.
- Typed errors per API error type, retries with idempotency keys,
  `if_match` and change notes.
- `assets.upload` in one call (paths or IO), and webhook verification
  (`Nohead::Webhooks.unwrap`). No runtime dependencies.
