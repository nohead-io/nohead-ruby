# frozen_string_literal: true

# Smoke test (Nohead spec §48.14): the core flow against a live API, with the
# installed gem. Needs NOHEAD_API_URL and NOHEAD_API_KEY (a key with schema,
# records, assets and webhooks read/write scopes). Exits non-zero on failure,
# after deleting what it created.
#
#   gem build nohead.gemspec && gem install --install-dir tmp/gems nohead-*.gem
#   GEM_HOME=tmp/gems NOHEAD_API_URL=http://localhost:3000 NOHEAD_API_KEY=sk_live_... ruby smoke/smoke.rb

require "nohead"
require "securerandom"
require "stringio"

def expect(condition, message)
  return if condition

  warn "FAIL: #{message}"
  exit 1
end

def raises(klass)
  yield
  nil
rescue klass => e
  e
end

nohead = Nohead::Client.new

# What the test created and has not deleted yet, by resource: deleted at the
# end, also when it fails.
left = {}

begin
  me = nohead.me.get
  expect(me.api_key&.project_id, "the key belongs to a project")

  collection = nohead.collections.create(
    name: "Ruby smoke", slug: "sdk-ruby-#{SecureRandom.hex(4)}",
    fields: [{ name: "Title", api_key: "title", type: "text", required: true }]
  )
  left[:collections] = collection.id

  key = SecureRandom.uuid
  first = nohead.records.create(collection.slug, data: { title: "One" }, idempotency_key: key)
  retried = nohead.records.create(collection.slug, data: { title: "One" }, idempotency_key: key)
  expect(retried.id == first.id, "an idempotent retry returns the same record")
  nohead.records.create(collection.slug, data: { title: "Two" })

  expect(nohead.records.get(first.id).data["title"] == "One", "get returns the record")

  updated = nohead.records.update(first.id, data: { title: "Uno" }, if_match: first)
  expect(updated.data["title"] == "Uno" && updated.revision == first.revision + 1, "update writes a revision")
  stale = raises(Nohead::PreconditionFailedError) do
    nohead.records.update(first.id, data: { title: "Stale" }, if_match: first)
  end
  expect(stale&.current_revision == updated.revision, "a stale if_match is a 412 with the current revision")

  page = nohead.records.list(collection.slug, limit: 1)
  expect(page.data.size == 1 && page.next_page?, "the first page has one record and more")
  expect(page.next_page.data.first.id != page.data.first.id, "the cursor returns the next page")
  titles = nohead.records.list(collection.slug, limit: 1).map { |record| record.data["title"] }.sort
  expect(titles == %w[Two Uno], "each walks every page")

  # A comma inside a value is escaped, or "Two" would match too.
  chosen = nohead.records.list(collection.slug, filter: { title: { in: ["Uno", "Two, or not"] } })
  expect(chosen.data.map { |record| record.data["title"] } == ["Uno"], "filters take operators")

  published = nohead.records.publish(first.id)
  expect(published.status == "published" && published.published_at, "publish publishes")
  expect(nohead.records.unpublish(first.id).status == "draft", "unpublish takes it back")

  invalid = raises(Nohead::ValidationError) { nohead.records.create(collection.slug, data: {}) }
  expect(invalid && invalid.details.first&.field == "title", "validation errors name the field")

  missing = raises(Nohead::NotFoundError) { nohead.records.get("rec_01J9ZQ3F8X5W2K7M4N6P0R1S2T") }
  expect(missing&.request_id&.start_with?("req_"), "API errors carry the request ID")

  asset = nohead.assets.upload(StringIO.new("hello"), filename: "hello.txt")
  left[:assets] = asset.id
  expect(asset.status == "ready" && asset.byte_size == 5, "assets upload to storage")
  expect(nohead.assets.delete(asset.id).deleted, "assets soft-delete")
  nohead.assets.purge(asset.id)
  left.delete(:assets)

  webhook = nohead.webhooks.create(url: "https://example.com/nohead-smoke", event_types: ["record.published"])
  left[:webhooks] = webhook.id
  rotated = nohead.webhooks.rotate_secret(webhook.id)
  expect(webhook.secret.start_with?("whsec_") && rotated.secret != webhook.secret,
         "rotating a webhook's secret replaces it")
  expect(nohead.webhooks.delete(webhook.id).deleted, "webhooks delete")
  left.delete(:webhooks)

  expect(nohead.records.delete(first.id).deleted, "delete soft-deletes")
  nohead.collections.delete(collection.id)
  left.delete(:collections)
ensure
  left.each do |resource, id|
    nohead.public_send(resource).delete(id)
  rescue Nohead::Error
    nil
  end
end

puts "ruby SDK smoke test passed"
