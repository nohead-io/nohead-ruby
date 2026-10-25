# Nohead Ruby SDK

The official Ruby client for the [Nohead](https://nohead.io) API: pages you can enumerate, retries that are safe for writes, one-call uploads and webhook verification. No runtime dependencies.

```ruby
require "nohead"

nohead = Nohead::Client.new # reads NOHEAD_API_KEY

nohead.records.list("posts", filter: { published_at: { exists: true } }).each do |post|
  puts post.data["title"]
end
```

> **Status:** 0.x until the Nohead API launches.

## Contents

- [Installation](#installation)
- [Configuration](#configuration)
- [Records](#records)
- [Drafts](#drafts)
- [Pagination](#pagination)
- [Errors](#errors)
- [Retries and idempotency](#retries-and-idempotency)
- [Concurrency](#concurrency)
- [Assets](#assets)
- [Search](#search)
- [Schema](#schema)
- [Webhooks](#webhooks)
- [Results](#results)
- [Reference](#reference)
- [Development](#development)
- [Releasing](#releasing)

## Installation

```ruby
gem "nohead"
```

It needs Ruby 3.3 or newer. It uses only Ruby's standard library (Net::HTTP, JSON, OpenSSL). Use it on servers: API keys are secrets.

## Configuration

```ruby
nohead = Nohead::Client.new(
  api_key: ENV.fetch("NOHEAD_API_KEY"), # default: NOHEAD_API_KEY
  base_url: "https://api.nohead.io" # default: NOHEAD_API_URL, else production
)
```

| Option | Default | |
|---|---|---|
| `api_key:` | `NOHEAD_API_KEY` | A project API key (`nohead_sk_...`, or `nohead_pk_...` when published-only). Required. |
| `base_url:` | `NOHEAD_API_URL`, else `https://api.nohead.io` | |
| `project_id:` | the key's project | Looked up once with `GET /v1/me` when omitted. |
| `max_retries:` | `2` | See [retries](#retries-and-idempotency). |
| `timeout:` | `60` | Seconds per attempt. |
| `headers:` | `{}` | Added to every request. |
| `warnings:` | `true` | Warns about deprecated operations and plan usage, once each. |

API keys belong to a project, so methods like `collections.list` need no project ID. Collections can be named by ID or slug everywhere.

## Records

```ruby
created = nohead.records.create("posts", data: { title: "Hello", author: "rec_01J9..." })
post = nohead.records.get(created.id, expand: ["author"])
nohead.records.update(post.id, data: { title: "Hello again" }) # nil clears a field
nohead.records.publish(post.id)
nohead.records.publication(post.id) # since when, by whom, which revision
nohead.records.schedule(post.id, unpublish_at: Time.utc(2027, 1, 1)) # the whole schedule: a time left out is cleared
nohead.records.delete(post.id) # soft delete; records.restore undoes it
```

Methods return the API's resources (see [Results](#results)) and raise on failure. Field values are under `data`, keyed by field API key.

**Upserts.** With `upsert_on:`, the key of a `unique` field, `create` updates the record holding that value instead, if one exists, so a content sync can run again without duplicates: `nohead.records.create("products", data: { sku: "TEE-01", title: "Tee" }, upsert_on: "sku")`.

**More:**

- `count`, and `bulk` (up to 100 records at once)
- `diff(record, from: 1, to: 2)`
- `revisions.list` (`filter:` `operation`, `actor_id` and a `created_at` range such as `{ gte: Time.utc(2026, 10, 1) }`), `revisions.get` and `revisions.revert` (with `dry_run: true` for a preview)
- a revision by its own ID, as webhooks and the activity log name it: `nohead.revisions.get("rev_...")`

## Drafts

A draft holds changes to a record until they are merged, now or at a set time, while the record keeps its current content: changes to review before they go live, or changes due later.

```ruby
draft = nohead.drafts.create(post.id, data: { title: "Hello, revised" })
nohead.drafts.update(draft.id, data: { summary: "..." }, if_match: draft)
preview = nohead.drafts.get(draft.id, expand: ["author"]) # data as it would read
nohead.drafts.merge(draft.id) # or drafts.schedule(draft.id, merge_at: ...)
```

- A record has at most one draft; starting a second raises `Nohead::ConflictError` (detail code `draft_exists`, with its `draft_id`).
- A merge changes content only: a live record stays live, an unpublished one unpublished. Publishing a live record with a pending draft raises `ConflictError` (`draft_pending`).
- `records.drafts(id)` lists a record's draft, and `drafts.list(collection)` a collection's.
- `drafts.discard` deletes one for good.

## Pagination

List methods return the first page, a `Nohead::Page`. It's Enumerable: `each`, `map`, `first` and so on walk every item across pages, fetching the next page only when needed.

```ruby
# Every record
nohead.records.list("posts").each { |record| ... }
nohead.records.list("posts").first(10) # fetches only what it needs

# One page at a time
page = nohead.records.list("posts", limit: 100)
page.data # this page's records
page.meta.next_cursor
page = page.next_page while page.next_page?

# Resume from a saved cursor
nohead.records.list("posts", cursor: saved_cursor)
```

Filters take a value to equal, or operators: `eq`, `ne`, `gt`, `gte`, `lt`, `lte`, `in` (an array) and `exists`. They combine with AND. On fields with several values, equal means "contains". Values are strings, numbers, booleans, Times (for date fields with a time) and Dates (for plain date fields, sent as `YYYY-MM-DD`); dates take `"today"` too, and dates with a time `"now"`. Lists sort by a field as well, with records that have no value last:

```ruby
nohead.records.list("posts", filter: { published_at: { exists: true }, featured: true, author: "rec_01J9..." },
                             sort: "-published_at", expand: %w[author tags])

nohead.records.list("products", filter: { price: { lt: 50 }, category: { in: %w[shoes bags] }, cover: { exists: true } },
                                sort: "price")
```

## Errors

Every error is a `Nohead::Error`. API errors are `Nohead::APIError`s with `status`, `type`, `message`, `request_id`, `details` and `headers`, in a class per type:

| Class | Status |
|---|---|
| `InvalidRequestError` | 400 |
| `AuthenticationError` | 401 |
| `PlanLimitExceededError` | 402 |
| `AuthorizationError` | 403 |
| `NotFoundError` | 404 |
| `ConflictError` | 409 |
| `PreconditionFailedError` | 412 (`current_revision`) |
| `ValidationError` | 422 |
| `RateLimitError` | 429 (`retry_after`) |
| `InternalServerError` | 500 and other 5xx |
| `ServiceUnavailableError` | 503 |

Other errors:

- `Nohead::ConnectionError`, and `Nohead::TimeoutError`, which is a kind of `ConnectionError`
- `Nohead::UploadError`
- `Nohead::WebhookVerificationError`

```ruby
begin
  nohead.records.create("posts", data: {})
rescue Nohead::ValidationError => e
  e.details.each { |detail| puts "#{detail.field}: #{detail.message}" }
end
```

## Retries and idempotency

Failed requests are retried twice by default (`max_retries:`), with exponential backoff:

- what's retried: connection errors, timeouts, 429, 500, 502, 503, 504, and a 409 for a request that is still running
- `Retry-After` is honored up to 60 seconds; a longer one raises `RateLimitError` straight away

Every write gets an `Idempotency-Key` that stays the same across its retries, so a retry after a lost response never writes twice. To make a write safe across your own retries (a job that may run twice), pass a key:

```ruby
nohead.records.create("posts", data: data, idempotency_key: "import-#{row.id}")
```

Writes that change records or the schema also take `change_note:`, a reason shown in history.

## Concurrency

Pass the revision you read to make sure nobody changed the record since:

```ruby
post = nohead.records.get(id)
begin
  nohead.records.update(id, data: { title: title }, if_match: post)
rescue Nohead::PreconditionFailedError => e
  # changed since (now at e.current_revision): reload, and merge or ask
end
```

`if_match:` takes a record (or draft) or a revision number, on `records.update`, `delete`, `restore`, `publish`, `unpublish` and `revisions.revert`, and on `drafts.update`, `discard` and `merge`.

## Assets

```ruby
asset = nohead.assets.upload("cover.jpg")
nohead.records.update(id, data: { cover: asset.id })

```

**Images.** Image URLs are open: an image's `image_url` serves the whole image, and any of [imgproxy's processing options](https://docs.imgproxy.net/usage/processing) written into it transform it. `Nohead::Images.url` builds them without a request:

```ruby
Nohead::Images.url(asset, width: 1200, height: 630, fit: "cover", gravity: "sm", format: "webp")
Nohead::Images.url(asset.image_url, width: 400, dpr: 2, options: ["bl:2"])
```

Thumbnails: an image's `preview_url` fits in 640×640, as WebP.

**What `upload` accepts:** a path (String or Pathname), or an IO opened in binary mode. For bytes in memory, pass `StringIO.new(bytes)`.

**What it does:**

1. Creates the upload.
2. Streams the bytes straight to storage.
3. Completes the upload, which checks the file, and returns the `ready` asset.

**Errors:** `UploadError` if storage refuses the bytes; `ValidationError` if the file fails the checks.

**Resuming:** with an `idempotency_key:`, running the same upload again resumes it: the key starts the upload, and an asset that is already `ready` comes back without sending the bytes again. Once the upload's URL has expired (its `upload.expires_at`), it raises `UploadError`: start over with a new key.

**Uploading from a browser:** create the upload on your server with `create_upload`, `PUT` the file from the browser, then `complete` it.

**Renaming and alt text:** `update` changes an asset's `filename:` and `alt:` text, the default wherever the asset is used (`expand:` returns it with the asset). The file itself never changes.

```ruby
nohead.assets.update(asset.id, alt: "The spring menu, on a chalkboard")
```

## Search

```ruby
# One collection
nohead.records.search("posts", "content model").each { |hit| ... }

# Across the project
results = nohead.search("content model", collections: %w[posts pages], filter: { published_at: { exists: true } })
results.meta.total_estimate
```

Search needs the `search:read` scope and covers every collection the key can read, matching their `searchable` fields. It pages through the first 1,000 hits. For search straight from a site's browser, without the API, use a search token from the web app with Meilisearch's own clients or InstantSearch.

## Schema

```ruby
nohead.collections.create(name: "Posts", slug: "posts",
                          fields: [{ name: "Title", key: "title", type: "text", required: true }])
nohead.fields.create("posts", name: "Summary", key: "summary", type: "long_text")

# Changes that rewrite records go through a migration; preview first
preview = nohead.migrations.create("posts", field_id: "fld_...", type: "long_text", dry_run: true)
migration = nohead.migrations.create("posts", field_id: "fld_...", type: "long_text")
nohead.migrations.get(migration.id)
```

For schema as code, see the `nohead` CLI (`nohead schema pull/diff/push`).

## Webhooks

Verify a webhook request, then use its event:

```ruby
# e.g. in a Rails controller
event = Nohead::Webhooks.unwrap(request.raw_post, request.headers,
                                secret: ENV.fetch("NOHEAD_WEBHOOK_SECRET"))
if event.type == "record.published"
  RebuildJob.perform_later(event.data.record.collection)
end
head :no_content
```

Event types are the same as the activity log's (`record.published`, `record.restored`, `field.updated`, `asset.purged`, ...), and a webhook subscribes to types or wildcards (`record.*`, `*`). `event.actor` says who made the change, and `event.via` through which client. `unwrap` checks the signature and the timestamp (Standard Webhooks), and raises `Nohead::WebhookVerificationError` if either is off. After `rotate_secret`, requests carry a signature for the old secret and the new one for 24 hours, so switch the receiver's secret within that day (or end it sooner with `webhooks.secrets.retire`). Pass the raw body: parsing and re-serializing JSON changes the bytes.

It's also available as `nohead.webhooks.unwrap` on a client. Events can arrive more than once, so deduplicate by the `webhook-id` header.

## Results

The API's resources come back as `Nohead::NoheadObject`s.

- **Reading fields:** use methods (`record.data`) or `[]` (`record[:data]`, `record["data"]`), at any depth.
- **Fields named like Ruby's own methods** (`method`, `hash`…) need `[]`.
- **Timestamps** (the API's: `created_at`, `purge_after`, a scheduled change's `at`...) are `Time`s. A record's field values (`record.data`) stay as they come.
- **Unknown fields are kept**, because the API adds fields and values without notice.
- **`to_h`** gives the raw Hash.

## Reference

| Resource | Methods |
|---|---|
| `records` | `list`, `get`, `create`, `update`, `delete`, `restore`, `publish`, `unpublish`, `publication`, `get_schedule`, `schedule`, `unschedule`, `scheduled_changes`, `drafts`, `count`, `bulk`, `diff`, `search` |
| `drafts` | `create`, `list`, `get`, `update`, `discard`, `merge`, `schedule`, `unschedule` |
| `records.revisions` | `list`, `get`, `revert` |
| `revisions` | `get` (by its own `rev_` ID) |
| `search` | across the project |
| `collections` | `list`, `get`, `create`, `update`, `delete`, `restore`, `schema` |
| `collections.schema_changes` | `list`, `get` |
| `collections.search_index` | `get`, `rebuild` |
| `fields` | `list`, `get`, `create`, `update`, `delete`, `restore`, `order`, `reorder`, `remove_alias` |
| `migrations` | `create`, `list`, `get`, `cancel` |
| `assets` | `upload`, `create_upload`, `complete`, `list`, `get`, `update`, `delete`, `restore`, `purge`, `usage` |
| `webhooks` | `list`, `get`, `create`, `update`, `delete`, `restore`, `rotate_secret`, `test`, `unwrap` |
| `webhooks.secrets` | `list`, `retire` |
| `webhooks.deliveries` | `list`, `get`, `retry` |
| `audit_events` | `list` |
| `feature_flags` | `list` |
| `me` | `get` |
| `health` | `check` |

The SDK covers every operation an API key can call. Organizations, projects, members and API keys are managed in the web app. The full API is documented at [docs.nohead.io](https://docs.nohead.io).

## Development

```bash
bundle install
bundle exec rake test       # unit and contract tests
bundle exec rubocop
bundle exec rake generate   # after updating openapi.json
bundle exec rake samples    # after changing test/calls.rb (the docs' code samples)
```

Before pushing, run what CI runs: the tests, RuboCop, and a check that the generated files are up to date:

```bash
bundle exec rake test
bundle exec rubocop
bundle exec rake generate samples && git diff --exit-code   # with your changes committed: a diff is a stale file
gem build nohead.gemspec
```

**How the code is organized:**

- `openapi.json` is the API's published contract. `rake generate` derives the operation table, `lib/nohead/operations.rb`, from it.
- The methods are written by hand.
- `test/contract_test.rb` runs every call in `test/calls.rb`. It fails when an API-key operation in the contract has no method, when a query parameter is never sent (no method takes it, or no call passes it), or when a request doesn't match its operation (method, path, query parameters and JSON body, against their schemas). Each call gets an example of its operation's response, built from the contract's schema, and must return it.
- The unit tests answer with `test/fake_transport.rb`, which checks every request to the API and every reply against `openapi.json`, so a fixture can't drift from the API. Wrap a reply that breaks the contract on purpose (a gateway's HTML page, an unknown error type) in `raw(...)`.

The smoke test (`smoke/smoke.rb`) runs the core flow against a real API, with the gem as installed from its built package. Nohead's own CI runs it on every API contract change.

## Releasing

1. Bump `lib/nohead/version.rb`.
2. Add a section for the version to `CHANGELOG.md` (`## 1.2.3`), which becomes the release's notes.
3. Merge to `main`. Its ruleset requires the **CI passed** check, so the commit goes through a pull request or a branch whose CI passed, and force pushes are refused.
4. Run the **SDK release** workflow in the Nohead API repository. It runs this commit's smoke test against the API and pushes the tag `v1.2.3`. Nobody else can push `v*` tags: a tag ruleset lets only that workflow's deploy key through.
5. The tag starts `.github/workflows/release.yml`. A build job checks the tag is on `main` and matches the version and its notes, and packs the gem, with no publishing credential. Its publishing job runs in the `release` environment, which only `v*` tags can use, and the registry's trusted publisher accepts only that environment. It pushes that gem to RubyGems through trusted publishing (no API key), then creates the GitHub release with the gem.

## License

MIT
