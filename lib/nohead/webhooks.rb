# frozen_string_literal: true

require "json"
require "openssl"

module Nohead
  # Verifying webhook requests (Standard Webhooks), with or without a client:
  #
  #   event = Nohead::Webhooks.unwrap(request.raw_post, request.headers,
  #                                   secret: ENV.fetch("NOHEAD_WEBHOOK_SECRET"))
  #   puts event.data.record.id if event.type == "record.published"
  module Webhooks
    # Checks a webhook request's signature and timestamp and returns its event
    # (a NoheadObject: `type`, `data`...). Pass the raw body exactly as
    # received: parsing and re-serializing JSON changes the bytes, and the
    # signature with them. Raises WebhookVerificationError when anything does
    # not match. `headers` is a Hash or anything with `[]` (any case).
    def self.unwrap(body, headers, secret:, tolerance: 300)
      id = header(headers, "webhook-id")
      timestamp = header(headers, "webhook-timestamp")
      signatures = header(headers, "webhook-signature")
      unless id && timestamp && signatures
        raise WebhookVerificationError, "Missing webhook-id, webhook-timestamp or webhook-signature header"
      end
      unless timestamp.match?(/\A\d+\z/) && (Time.now.to_i - timestamp.to_i).abs <= tolerance
        raise WebhookVerificationError, "The webhook timestamp is too far from the current time"
      end

      key = secret.delete_prefix("whsec_").unpack1("m0")
      expected = [OpenSSL::HMAC.digest("SHA256", key, "#{id}.#{timestamp}.#{body}")].pack("m0")
      matched = signatures.split.any? do |entry|
        version, signature = entry.split(",", 2)
        version == "v1" && signature && OpenSSL.secure_compare(signature, expected)
      end
      raise WebhookVerificationError, "No webhook signature matches" unless matched

      NoheadObject.wrap(JSON.parse(body))
    rescue ArgumentError
      raise WebhookVerificationError, "The webhook secret is not base64"
    rescue JSON::ParserError
      raise WebhookVerificationError, "The webhook body is not JSON"
    end

    def self.header(headers, name)
      return headers[name] || headers[name.split("-").map(&:capitalize).join("-")] unless headers.is_a?(Hash)

      headers.find { |key, _| key.to_s.downcase == name }&.last
    end
    private_class_method :header
  end

  module Resources
    # Webhooks of the key's project. `webhook` is a webhook ID ("wh_...").
    class Webhooks < Resource
      attr_reader :deliveries

      def initialize(client)
        super
        @deliveries = Deliveries.new(client)
      end

      def list(limit: nil, cursor: nil)
        @client.paginate("webhooks_list", query: { limit: limit, cursor: cursor })
      end

      def get(webhook)
        @client.request("webhooks_get", path: { webhook_id: webhook })
      end

      # Subscribes a URL. The response is the only time `secret` is shown.
      def create(idempotency_key: nil, **params)
        @client.request("webhooks_create", body: params, idempotency_key: idempotency_key)
      end

      def update(webhook, idempotency_key: nil, **params)
        @client.request("webhooks_update", path: { webhook_id: webhook }, body: params,
                                           idempotency_key: idempotency_key)
      end

      def delete(webhook, idempotency_key: nil)
        @client.request("webhooks_delete", path: { webhook_id: webhook }, idempotency_key: idempotency_key)
      end

      # A new signing secret; the old one stops working at once.
      def rotate_secret(webhook, idempotency_key: nil)
        @client.request("webhooks_rotate_secret", path: { webhook_id: webhook },
                                                  idempotency_key: idempotency_key)
      end

      # Sends a `webhook.test` event to the URL.
      def test(webhook, idempotency_key: nil)
        @client.request("webhooks_test", path: { webhook_id: webhook }, idempotency_key: idempotency_key)
      end

      # Checks a webhook request's signature and returns its event (see
      # Nohead::Webhooks.unwrap, which needs no client).
      def unwrap(body, headers, secret:, tolerance: 300)
        Nohead::Webhooks.unwrap(body, headers, secret: secret, tolerance: tolerance)
      end
    end

    # Delivery attempts of a webhook's events.
    class Deliveries < Resource
      def list(webhook, status: nil, limit: nil, cursor: nil)
        @client.paginate("webhook_deliveries_list", path: { webhook_id: webhook },
                                                    query: { status: status, limit: limit, cursor: cursor })
      end

      def get(delivery)
        @client.request("webhook_deliveries_get", path: { delivery_id: delivery })
      end

      # Sends the event again.
      def retry(delivery, idempotency_key: nil)
        @client.request("webhook_deliveries_retry", path: { delivery_id: delivery },
                                                    idempotency_key: idempotency_key)
      end
    end
  end
end
