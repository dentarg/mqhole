require "json"

module Mqhole
  module CloudAMQP
    struct Region
      include JSON::Serializable

      getter provider : String
      getter region : String
      getter name : String
      getter has_shared_plans : Bool

      def initialize(@provider : String, @region : String, @name : String, @has_shared_plans : Bool)
      end

      def identifier : String
        "#{provider}::#{region}"
      end
    end
  end
end
