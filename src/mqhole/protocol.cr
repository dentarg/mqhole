require "digest/sha256"

module Mqhole
  module Protocol
    PREFIX = "mqhole.v1"

    def self.queue_name(name : String) : String
      "#{PREFIX}.#{Digest::SHA256.hexdigest(name)}"
    end
  end
end
