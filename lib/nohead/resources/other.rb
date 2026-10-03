# frozen_string_literal: true

module Nohead
  module Resources
    # The project's activity log, newest first. Needs the audit:read scope.
    class AuditEvents < Resource
      # `filter` takes action (exact, or a "record.*" prefix), resource_type,
      # resource_id, actor_type, actor_id, since and until.
      def list(filter: nil, sort: nil, limit: nil, cursor: nil)
        @client.paginate("audit_events_list_for_project",
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
