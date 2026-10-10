# frozen_string_literal: true

# One call per API-key operation, with arguments as the docs should show
# them. The contract test runs every call against the contract, and
# scripts/samples.rb turns each into the API reference's code sample for the
# operation it calls (samples.json).
require_relative "spec"

module Calls
  EVERY_CALL = [
    ->(nohead) { nohead.records.list("posts", filter: { status: "published" }, sort: "-created_at", expand: ["author"], limit: 5) },
    ->(nohead) { nohead.records.get("rec_01J9ZQ3F8X", expand: ["author"], include_deleted: true) },
    ->(nohead) { nohead.records.create("posts", data: { title: "Hi" }) },
    ->(nohead) { nohead.records.update("rec_01J9ZQ3F8X", data: { title: "Hey" }, if_match: 1) },
    ->(nohead) { nohead.records.delete("rec_01J9ZQ3F8X") },
    ->(nohead) { nohead.records.restore("rec_01J9ZQ3F8X") },
    ->(nohead) { nohead.records.publish("rec_01J9ZQ3F8X") },
    ->(nohead) { nohead.records.unpublish("rec_01J9ZQ3F8X") },
    ->(nohead) { nohead.records.schedule("rec_01J9ZQ3F8X", publish_at: Time.utc(2027, 1, 1)) },
    ->(nohead) { nohead.records.unschedule("rec_01J9ZQ3F8X") },
    ->(nohead) { nohead.records.count("posts", filter: { status: "draft" }) },
    ->(nohead) { nohead.records.bulk("posts", action: "publish", record_ids: ["rec_01J9ZQ3F8X"]) },
    ->(nohead) { nohead.records.diff("rec_01J9ZQ3F8X", 1, 2) },
    ->(nohead) { nohead.records.search("posts", "hello", filter: { status: "published" }, sort: "-published_at", expand: ["author"]) },
    ->(nohead) { nohead.records.revisions.list("rec_01J9ZQ3F8X", filter: { operation: "update" }) },
    ->(nohead) { nohead.records.revisions.get("rec_01J9ZQ3F8X", 1) },
    ->(nohead) { nohead.records.revisions.revert("rec_01J9ZQ3F8X", 1, dry_run: true) },
    ->(nohead) { nohead.search("hello", collections: ["posts"], status: "published") },
    ->(nohead) { nohead.collections.list(deleted: true) },
    ->(nohead) { nohead.collections.get("posts") },
    ->(nohead) { nohead.collections.create(name: "Posts", slug: "posts") },
    ->(nohead) { nohead.collections.update("posts", name: "Articles") },
    ->(nohead) { nohead.collections.delete("posts") },
    ->(nohead) { nohead.collections.restore("posts") },
    ->(nohead) { nohead.collections.schema("posts", version: 2) },
    ->(nohead) { nohead.collections.schema_changes.list("posts") },
    ->(nohead) { nohead.collections.schema_changes.get("posts", "sch_01J9ZQ3F8X") },
    ->(nohead) { nohead.collections.search_index.get("posts") },
    ->(nohead) { nohead.collections.search_index.rebuild("posts") },
    ->(nohead) { nohead.fields.list("posts", deleted: true) },
    ->(nohead) { nohead.fields.create("posts", name: "Title", api_key: "title", type: "text") },
    ->(nohead) { nohead.fields.update("fld_01J9ZQ3F8X", name: "Heading") },
    ->(nohead) { nohead.fields.delete("fld_01J9ZQ3F8X") },
    ->(nohead) { nohead.fields.restore("fld_01J9ZQ3F8X") },
    ->(nohead) { nohead.fields.reorder("posts", ["fld_01J9ZQ3F8X"]) },
    ->(nohead) { nohead.fields.remove_alias("fld_01J9ZQ3F8X", "old_title") },
    ->(nohead) { nohead.fields.migrate("fld_01J9ZQ3F8X", type: "long_text", dry_run: true) },
    ->(nohead) { nohead.migrations.list("posts") },
    ->(nohead) { nohead.migrations.get("mig_01J9ZQ3F8X") },
    ->(nohead) { nohead.migrations.cancel("mig_01J9ZQ3F8X") },
    ->(nohead) { nohead.assets.upload(StringIO.new("Hello"), filename: "hello.txt") },
    ->(nohead) { nohead.assets.create_upload(filename: "hello.txt", content_type: "text/plain", byte_size: 5) },
    ->(nohead) { nohead.assets.complete("ast_01J9ZQ3F8X") },
    ->(nohead) { nohead.assets.list(deleted: true) },
    ->(nohead) { nohead.assets.get("ast_01J9ZQ3F8X") },
    ->(nohead) { nohead.assets.delete("ast_01J9ZQ3F8X") },
    ->(nohead) { nohead.assets.restore("ast_01J9ZQ3F8X") },
    ->(nohead) { nohead.assets.purge("ast_01J9ZQ3F8X") },
    ->(nohead) { nohead.assets.usage("ast_01J9ZQ3F8X") },
    ->(nohead) { nohead.assets.image_url("ast_01J9ZQ3F8X", width: 100, format: "webp") },
    ->(nohead) { nohead.assets.download_url("ast_01J9ZQ3F8X") },
    ->(nohead) { nohead.webhooks.list },
    ->(nohead) { nohead.webhooks.get("wh_01J9ZQ3F8X") },
    ->(nohead) { nohead.webhooks.create(url: "https://example.com/hook", event_types: ["*"]) },
    ->(nohead) { nohead.webhooks.update("wh_01J9ZQ3F8X", enabled: false) },
    ->(nohead) { nohead.webhooks.delete("wh_01J9ZQ3F8X") },
    ->(nohead) { nohead.webhooks.rotate_secret("wh_01J9ZQ3F8X") },
    ->(nohead) { nohead.webhooks.test("wh_01J9ZQ3F8X") },
    ->(nohead) { nohead.webhooks.deliveries.list("wh_01J9ZQ3F8X", status: "failed") },
    ->(nohead) { nohead.webhooks.deliveries.get("whd_01J9ZQ3F8X") },
    ->(nohead) { nohead.webhooks.deliveries.retry("whd_01J9ZQ3F8X") },
    ->(nohead) { nohead.audit_events.list(filter: { action: "record.*" }, sort: "-id") },
    ->(nohead) { nohead.feature_flags.list },
    ->(nohead) { nohead.me.get },
    ->(nohead) { nohead.health.check }
  ].freeze

  # The reply to any of the calls above: the contract's example of the
  # operation's success response (test/spec.rb), with an upload URL on storage.
  def self.reply(request)
    return Nohead::Response.new(200, {}, "") if request.uri.host == "storage.test"

    route = Spec.route_of(request.method, request.path)
    Nohead::Response.new(route.status, { "content-type" => "application/json" },
                         JSON.generate(example_reply(route, request)))
  end

  # The body of `reply` for a request of an operation.
  def self.example_reply(route, request)
    schema = route.response.schema
    # A dry run's reply is the preview, the last of oneOf (records.revisions.revert).
    schema = schema["oneOf"].last if request.params["dry_run"] == "true" && schema["oneOf"]
    body = JSON.parse(JSON.generate(Spec.example(schema))) # a copy: examples are the contract's
    body["upload"]["url"] = "https://storage.test/u" if route.id == "assets_upload"
    body
  end
end
