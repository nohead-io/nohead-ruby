# Changelog

Changes to the `nohead` gem that you can notice. Versions follow
[Semantic Versioning](https://semver.org): additive API changes are minor
releases; a change that could break your code is a major one. Each release's
section is its GitHub release's notes.

## 0.3.0

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
  - `records.schedule` and `unschedule` return the schedule, and
    `records.get_schedule`, `records.publication` and
    `records.scheduled_changes` are new. `records.bulk` returns a record
    batch.
  - `search` takes `published: true` instead of `status: "published"`.
  - Collections, fields, assets and webhooks have `deleted_at` and
    `purge_after` instead of `deleted`, and migrations
    `cancel_requested_at`.
  - `assets.create_upload` returns the asset with its `upload`.
  - `fields.reorder` returns the field order; `fields.order` reads it.
  - Webhook event types are the activity log's actions (`record.restored`,
    `field.updated`, ..., and wildcards such as `record.*`), and events carry
    `actor` and `via`. `webhooks.rotate_secret` returns the new webhook
    secret with its value; the old secret signs for 24 hours more.
    `webhooks.secrets.list`, `webhooks.secrets.retire`, `webhooks.restore`
    and `webhooks.list(deleted: true)` are new.
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
- `assets.purge`: permanently deletes a deleted asset now, instead of 30
  days after the delete, and frees its storage.
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
