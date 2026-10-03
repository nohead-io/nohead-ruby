# frozen_string_literal: true

# The official Ruby SDK for the Nohead API.
#
#   require "nohead"
#
#   nohead = Nohead::Client.new # NOHEAD_API_KEY
#   nohead.records.list("posts", filter: { status: "published" }).each do |post|
#     puts post.data["title"]
#   end
module Nohead; end

require_relative "nohead/version"
require_relative "nohead/nohead_object"
require_relative "nohead/errors"
require_relative "nohead/operations"
require_relative "nohead/page"
require_relative "nohead/transport"
require_relative "nohead/uploads"
require_relative "nohead/resources/records"
require_relative "nohead/resources/schema"
require_relative "nohead/resources/assets"
require_relative "nohead/resources/other"
require_relative "nohead/webhooks"
require_relative "nohead/client"
