# frozen_string_literal: true

require_relative "test_helper"
require "openssl"

class WebhooksTest < Minitest::Test
  include Helpers

  SECRET = "whsec_#{['a-very-secret-key'].pack('m0')}".freeze
  OTHER_SECRET = "whsec_#{['another-secret-key'].pack('m0')}".freeze

  def body
    JSON.generate(id: "wev_1", object: "event", type: "record.published",
                  created_at: "2026-10-02T12:00:00.000Z", project_id: "prj_1",
                  data: { record: record("rec_1", title: "Hi"), revision: 2, revision_id: "rev_1" })
  end

  def sign(payload, timestamp: Time.now.to_i, id: "msg_1", secret: SECRET)
    key = secret.delete_prefix("whsec_").unpack1("m0")
    digest = OpenSSL::HMAC.digest("SHA256", key, "#{id}.#{timestamp}.#{payload}")
    { "webhook-id" => id, "webhook-timestamp" => timestamp.to_s,
      "webhook-signature" => "v1,#{[digest].pack('m0')}" }
  end

  def test_returns_the_event
    event = Nohead::Webhooks.unwrap(body, sign(body), secret: SECRET)
    assert_equal "record.published", event.type
    assert_equal 2, event.data.revision
    assert_equal "Hi", event.data.record.data["title"]
  end

  def test_any_header_case_and_several_signatures
    headers = sign(body).transform_keys { |key| key.split("-").map(&:capitalize).join("-") }
    headers["Webhook-Signature"] = "v1,bm90LWl0 #{headers['Webhook-Signature']}"
    assert_equal "wev_1", Nohead::Webhooks.unwrap(body, headers, secret: SECRET).id
  end

  def test_from_the_client
    nohead, = client([])
    assert_equal "prj_1", nohead.webhooks.unwrap(body, sign(body), secret: SECRET).project_id
  end

  def test_rejects_bad_requests
    cases = {
      "changed body" => [body.sub("Hi", "Bye"), sign(body)],
      "wrong secret" => [body, sign(body, secret: OTHER_SECRET)],
      "old timestamp" => [body, sign(body, timestamp: Time.now.to_i - 600)],
      "timestamp not a number" => [body, sign(body).merge("webhook-timestamp" => "soon")],
      "missing headers" => [body, {}],
      "body not JSON" => ["not json", sign("not json")]
    }
    cases.each do |name, (payload, headers)|
      assert_raises(Nohead::WebhookVerificationError, name) do
        Nohead::Webhooks.unwrap(payload, headers, secret: SECRET)
      end
    end
  end

  def test_rejects_a_secret_that_is_not_base64
    error = assert_raises(Nohead::WebhookVerificationError) do
      Nohead::Webhooks.unwrap(body, sign(body), secret: "whsec_not base64!")
    end
    assert_match(/not base64/, error.message)
  end
end
