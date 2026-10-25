# frozen_string_literal: true

require_relative "test_helper"
require "standardwebhooks"

# Nohead::Webhooks.unwrap verifies signatures itself. These tests check it
# against the official Standard Webhooks library: it accepts what that library
# signs, rejects what that library rejects, and raises only
# WebhookVerificationError for any request, whatever its bytes.
class StandardWebhooksTest < Minitest::Test
  NOW = Time.utc(2026, 10, 2, 12)
  SECRET = "whsec_#{['a-very-secret-key'].pack('m0')}".freeze
  OTHER_SECRET = "whsec_#{['another-secret-key'].pack('m0')}".freeze
  BODY = '{"type":"record.published","data":{"title":"Grüße, 世界 🎉"}}'

  def setup
    Clock.now = NOW
  end

  def teardown
    Clock.now = nil
  end

  # A request signed by the official library.
  def signed(body = BODY, id: "msg_1", timestamp: NOW.to_i, secret: SECRET)
    signature = StandardWebhooks::Webhook.new(secret).sign(id, timestamp.to_s, body)
    { "webhook-id" => id, "webhook-timestamp" => timestamp.to_s, "webhook-signature" => signature }
  end

  def unwrap(body, headers, secret: SECRET)
    Nohead::Webhooks.unwrap(body, headers, secret: secret)
  end

  def test_accepts_what_the_official_library_signs
    bodies = [BODY, "{}", "{\"emoji\":\"\u{1F600}\"}", JSON.generate(text: "ÆØÅ æøå € ✓")]
    bodies.each do |body|
      assert_equal JSON.parse(body), unwrap(body, signed(body)).to_h, body
      # Rack hands over the raw body as binary.
      assert_equal JSON.parse(body), unwrap(body.b, signed(body)).to_h, body
    end
  end

  def test_accepts_non_ascii_headers_and_body_in_any_encoding
    headers = signed(id: "msg_é")
    [[BODY, headers], [BODY.b, headers], [BODY, headers.transform_values(&:b)],
     [BODY.b, headers.transform_values(&:b)]].each do |body, request_headers|
      assert_equal "record.published", unwrap(body, request_headers).type
    end
  end

  def test_accepts_several_signatures_in_one_header
    old = signed(secret: OTHER_SECRET)["webhook-signature"]
    current = signed["webhook-signature"]
    ["#{old} #{current}", "#{current} #{old}", "v2,#{current[3..]} v1,bm90LWl0 #{old} #{current}",
     "v1,é #{old}  #{current}"].each do |signatures|
      headers = signed.merge("webhook-signature" => signatures)
      [SECRET, OTHER_SECRET].each { |secret| StandardWebhooks::Webhook.new(secret).verify(BODY, headers) }
      assert_equal "record.published", unwrap(BODY, headers).type, signatures
      assert_equal "record.published", unwrap(BODY, headers, secret: OTHER_SECRET).type, signatures
    end
  end

  # Requests unwrap rejects, as [body, headers], with what the official
  # library raises for them. Each is its own test.
  REJECTED = {
    "tampered body" => [-> { [BODY.sub("Grüße", "Hallo"), signed] }],
    "wrong secret" => [-> { [BODY, signed(secret: OTHER_SECRET)] }],
    "old timestamp" => [-> { [BODY, signed(timestamp: NOW.to_i - 301)] }],
    "future timestamp" => [-> { [BODY, signed(timestamp: NOW.to_i + 301)] }],
    "timestamp not a number" => [-> { [BODY, signed.merge("webhook-timestamp" => "soon")] }],
    "changed webhook-id" => [-> { [BODY, signed.merge("webhook-id" => "msg_2")] }],
    "signature of another version" =>
      [-> { [BODY, signed.merge("webhook-signature" => signed["webhook-signature"].sub("v1,", "v2,"))] }],
    "signature not base64" => [-> { [BODY, signed.merge("webhook-signature" => "v1,not base64!")] }],
    "non-ASCII signature" => [-> { [BODY, signed.merge("webhook-signature" => "v1,#{'é' * 22}")] }],
    "non-ASCII signature of the right length" =>
      [-> { [BODY, signed.merge("webhook-signature" => "v1,é#{signed['webhook-signature'][5..]}")] }],
    "missing headers" => [-> { [BODY, {}] }],
    # Signed, but no event: the official library returns what JSON.parse raises.
    "body not JSON" => [-> { ["not json", signed("not json")] }, JSON::ParserError]
  }.freeze

  REJECTED.each do |name, (request, official)|
    define_method("test_rejects_#{name.gsub(/\W+/, '_')}") do
      body, headers = instance_exec(&request)
      assert_raises(official || StandardWebhooks::WebhookVerificationError) { StandardWebhooks::Webhook.new(SECRET).verify(body, headers) }
      assert_raises(Nohead::WebhookVerificationError) { unwrap(body, headers) }
    end
  end

  INVALID = (+"\xFF\xFE").force_encoding(Encoding::UTF_8).freeze

  # Headers that are not valid UTF-8, or not ASCII, are refused with
  # WebhookVerificationError and a message about the header, never with
  # ArgumentError or Encoding::CompatibilityError (the official library 1.1.0
  # raises those for some of these).
  BAD_HEADERS = {
    "signature not UTF-8" => [-> { signed.merge("webhook-signature" => "v1,#{INVALID}") }, /signature/],
    "signature not UTF-8, then a valid one of another secret" =>
      [-> { signed.merge("webhook-signature" => "v1,#{INVALID} #{signed(secret: OTHER_SECRET)['webhook-signature']}") },
       /signature/],
    "timestamp not UTF-8" => [-> { signed.merge("webhook-timestamp" => INVALID) }, /timestamp/],
    "timestamp in other digits" => [-> { signed.merge("webhook-timestamp" => "١٦١٤٢٦٥٣٣٠") }, /timestamp/],
    "webhook-id not UTF-8" => [-> { signed.merge("webhook-id" => "msg_#{INVALID}") }, /signature/],
    "non-ASCII webhook-id" => [-> { signed.merge("webhook-id" => "msg_é") }, /signature/],
    "non-ASCII binary webhook-id" => [-> { signed.merge("webhook-id" => "msg_é".b) }, /signature/]
  }.freeze

  BAD_HEADERS.each do |name, (headers, message)|
    define_method("test_rejects_a_#{name.gsub(/\W+/, '_')}") do
      [BODY, BODY.b].each do |body|
        error = assert_raises(Nohead::WebhookVerificationError) { unwrap(body, instance_exec(&headers)) }
        assert_match message, error.message
      end
    end
  end

  # The official library decodes the secret leniently (Base64.decode64 skips
  # what isn't base64), so it signs with any secret; unwrap refuses one that
  # is not strict base64.
  NOT_BASE64 = {
    "with a space" => "whsec_not base64!", "non-ASCII" => "whsec_é",
    "base64 then non-ASCII" => "whsec_#{['a-very-secret-key'].pack('m0')}é",
    "not UTF-8" => (+"whsec_\xFF").force_encoding(Encoding::UTF_8), "in UTF-16" => SECRET.encode(Encoding::UTF_16LE)
  }.freeze

  NOT_BASE64.each do |name, secret|
    define_method("test_rejects_a_secret_#{name.gsub(/\W+/, '_')}") do
      error = assert_raises(Nohead::WebhookVerificationError) { unwrap(BODY, signed, secret: secret) }
      assert_match(/not base64/, error.message)
    end
  end
end
