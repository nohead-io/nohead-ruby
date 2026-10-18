# frozen_string_literal: true

module Nohead
  module Resources
    # The project's activity log, newest first. Needs the audit:read scope.
    class AuditEvents < Resource
      # `filter` takes `type` (exact, or a "record.*" prefix), `resource_type`
      # (a type, or an Array of them), `resource_id`, `actor_type`, `actor_id`
      # and a `created_at` range:
      #
      #   audit_events.list(filter: { type: "record.*", resource_type: %w[record draft],
      #                               created_at: { gte: Time.utc(2026, 10, 1) } })
      #
      # `sort` is "-created_at" (the default) or "created_at".
      def list(filter: nil, sort: nil, limit: nil, cursor: nil)
        filter = filter&.transform_keys(&:to_sym)
        types = filter&.[](:resource_type)
        filter = filter.merge(resource_type: { in: types }) if types.is_a?(Array)
        @client.paginate("audit_events_list",
                         query: { filter: filter, sort: sort, limit: limit, cursor: cursor })
      end
    end

    # Feature flags evaluated for the key's project.
    class FeatureFlags < Resource
      # Flags evaluated for the key's project.
      def list
        @client.request("feature_flags_list")
      end
    end

    # The credentials the client uses.
    class Me < Resource
      # The API key: its project, scopes, published_only and expiry.
      def get
        @client.request("me_get")
      end
    end

    # Whether the API is up.
    class Health < Resource
      def check
        @client.request("health_check")
      end
    end
  end
end
