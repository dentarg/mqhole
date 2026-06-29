require "json"
require "base64"
require "http/client"
require "uri"

module Mqhole
  module CloudAMQP
    API_ENDPOINT = "https://customer.cloudamqp.com/api"
    PLAN         = "lemming"
    BACKEND      = "lavinmq"
    TAG          = "mqhole"

    struct Request
      getter method : String
      getter path : String
      getter body : String?

      def initialize(@method : String, @path : String, @body : String? = nil)
      end
    end

    struct Response
      getter status : Int32
      getter body : String

      def initialize(@status : Int32, @body : String)
      end

      def success? : Bool
        200 <= status < 300
      end
    end

    abstract class Transport
      abstract def request(request : Request) : Response
    end

    class HTTPTransport < Transport
      def initialize(@api_key : String, endpoint : String = API_ENDPOINT)
        @endpoint = endpoint.rstrip('/')
      end

      def request(request : Request) : Response
        headers = HTTP::Headers{
          "Accept"        => "application/json",
          "Authorization" => "Basic #{Base64.strict_encode(":#{@api_key}")}",
        }
        body = request.body
        headers["Content-Type"] = "application/json" if body

        response = HTTP::Client.exec(
          request.method,
          "#{@endpoint}#{request.path}",
          headers: headers,
          body: body
        )
        Response.new(response.status_code, response.body)
      end
    end

    class APIError < Exception
      getter status : Int32
      getter body : String

      def initialize(@status : Int32, @body : String)
        super("CloudAMQP API error status=#{status} message=#{self.class.message_from(body)}")
      end

      def self.message_from(body : String) : String
        json = JSON.parse(body)
        json["error"]?.try(&.as_s?) ||
          json["message"]?.try(&.as_s?) ||
          body
      rescue JSON::ParseException
        body
      end
    end

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

    struct Plan
      include JSON::Serializable

      getter name : String
      getter price : Float64?
      getter backend : String?
      getter shared : Bool?
    end

    struct InstanceURLs
      include JSON::Serializable

      getter external : String?
      getter internal : String?
    end

    struct Instance
      include JSON::Serializable

      getter id : Int64
      getter name : String?
      getter plan : String?
      getter region : String?
      getter tags : Array(String)?
      getter url : String?
      getter urls : InstanceURLs?
      getter apikey : String?
      getter ready : Bool?

      def connection_url : String?
        urls.try(&.external) || url
      end

      def ready_for_amqp? : Bool
        !!connection_url && ready == true
      end
    end

    class Client
      def initialize(@transport : Transport)
      end

      def self.with_api_key(api_key : String) : self
        new(HTTPTransport.new(api_key))
      end

      def regions(provider : String? = nil) : Array(Region)
        path = "/regions"
        if provider
          query = URI::Params.build do |params|
            params.add("provider", provider)
          end
          path = "#{path}?#{query}"
        end

        Array(Region).from_json(request("GET", path))
      end

      def plans(backend : String? = BACKEND) : Array(Plan)
        path = "/plans"
        if backend
          query = URI::Params.build do |params|
            params.add("backend", backend)
          end
          path = "#{path}?#{query}"
        end

        Array(Plan).from_json(request("GET", path))
      end

      def instances : Array(Instance)
        Array(Instance).from_json(request("GET", "/instances"))
      end

      def instance(id : Int) : Instance
        Instance.from_json(request("GET", "/instances/#{id}"))
      end

      def ensure_instance(
        region : String,
        wait_timeout : Time::Span = 3.minutes,
        poll_interval : Time::Span = 5.seconds,
      ) : Instance
        existing = instances.find do |instance|
          instance.name == self.class.instance_name(region) &&
            instance.plan == PLAN &&
            instance.region == region
        end

        return wait_for_instance(existing.id, wait_timeout, poll_interval) if existing

        created = create_instance(region)
        return created if created.ready_for_amqp?

        wait_for_instance(created.id, wait_timeout, poll_interval)
      end

      def create_instance(region : String) : Instance
        body = JSON.build do |json|
          json.object do
            json.field "name", self.class.instance_name(region)
            json.field "plan", PLAN
            json.field "region", region
            json.field "tags" do
              json.array do
                json.string TAG
              end
            end
          end
        end

        Instance.from_json(request("POST", "/instances", body))
      end

      def self.instance_name(region : String) : String
        slug = region.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/^-|-$/, "")
        "#{TAG}-#{BACKEND}-#{slug}"
      end

      private def wait_for_instance(id : Int, timeout : Time::Span, poll_interval : Time::Span) : Instance
        deadline = Time.instant + timeout

        loop do
          current = instance(id)
          return current if current.ready_for_amqp?
          raise APIError.new(504, "timed out waiting for instance #{id}") if Time.instant >= deadline

          sleep poll_interval
        end
      end

      private def request(method : String, path : String, body : String? = nil) : String
        response = @transport.request(Request.new(method, path, body))
        raise APIError.new(response.status, response.body) unless response.success?

        response.body
      end
    end
  end
end
