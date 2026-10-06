# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "nohead"
require "minitest/autorun"
require "json"
require "stringio"

# Retries wait no time in tests; `pauses` lists the waits they asked for.
Nohead::Client.prepend(Module.new do
  def pauses = @pauses ||= []
  def pause(seconds) = pauses << seconds
end)

require_relative "fake_transport"

module Helpers
  def client(replies, **)
    transport = FakeTransport.new(replies)
    nohead = Nohead::Client.new(api_key: "sk_live_test", base_url: "https://api.test",
                                project_id: "prj_1", transport: transport, **)
    [nohead, transport]
  end

  def json(status, body, headers = {})
    Nohead::Response.new(status, { "content-type" => "application/json" }.merge(headers),
                         JSON.generate(body))
  end

  def api_error(status, type, headers = {}, **extra)
    json(status, { error: { type: type, message: "#{type} message", request_id: "req_1", **extra } },
         headers)
  end

  def record(id, **data)
    {
      id: id, object: "record", collection_id: "col_1", collection: "posts", status: "draft",
      published_at: nil, schedule: { publish_at: nil, unpublish_at: nil, last_error: nil },
      revision: 1, schema_version: 1, history_pruned_through: nil, deleted: false, data: data,
      created_at: "2026-10-02T12:00:00.000Z", updated_at: "2026-10-02T12:00:00.000Z"
    }
  end

  def page(items, next_cursor, **meta)
    json(200, { data: items, meta: { next_cursor: next_cursor, has_more: !next_cursor.nil?, **meta } })
  end
end
