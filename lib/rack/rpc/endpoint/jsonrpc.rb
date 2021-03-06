require 'json' unless defined?(JSON)

class Rack::RPC::Endpoint
  ##
  # @see http://en.wikipedia.org/wiki/JSON-RPC
  # @see http://groups.google.com/group/json-rpc/web/json-rpc-2-0
  module JSONRPC
    CONTENT_TYPE = 'application/json; charset=UTF-8'
    VERSION      = 2.0

    ##
    # @see http://groups.google.com/group/json-rpc/web/json-rpc-2-0
    class Server
      ##
      # @param  [Rack::RPC::Server] server
      # @param  [Hash{Symbol => Object}] options
      def initialize(server, options = {})
        @server, @options = server, options.dup
      end

      ##
      # @param  [Rack::Request] request
      # @return [Rack::Response]
      def execute(request)
        # Store the request so that it can be accessed from the server methods:
        @server.request = request if @server.respond_to?(:request=)

        request_body = request.body.read
        request_body.force_encoding(Encoding::UTF_8) if request_body.respond_to?(:force_encoding) # Ruby 1.9+

        Rack::Response.new([process(request_body, request)], 200, {
          'Content-Type' => (request.content_type || CONTENT_TYPE).to_s,
        })
      end

      ##
      # @param  [String] input
      # @param  [Object] context
      # @return [String]
      def process(input, context = nil)
        response = nil
        begin
          response = case (json = JSON.parse(input))
            when Array then process_batch(json, context)
            when Hash  then process_request(json, context)
          end
        rescue JSON::ParserError => exception
          if @server.respond_to?(:rack_parse_error_handler)
            response = JSONRPC::Response.new
            response.error = @server.rack_parse_error_handler exception
          else
            response = JSONRPC::Response.new
            response.error = JSONRPC::ParseError.new(:message => exception.to_s)
          end
        end
        response.to_json + "\n"
      end

      ##
      # @param  [Array<Hash>] batch
      # @param  [Object] context
      # @return [Array]
      def process_batch(batch, context = nil)
        batch.map { |struct| process_request(struct, context) }
      end

      ##
      # @param  [Hash] struct
      # @param  [Object] context
      # @return [Hash]
      def process_request(struct, context = nil)
        response = JSONRPC::Response.new
        begin
          request = JSONRPC::Request.new(struct, context)
          response.id = request.id

          unless request.valid?
            Rack::RPC::Logger.log.debug "Method: #{request.method}, Version: #{request.version}, " \
                                        "Request id: #{request.id}, Params: #{request.params}"
            raise ::TypeError, "invalid JSON-RPC request"
          end

          case operator = @server.class[request.method]
            when nil
              raise ::NoMethodError, "undefined operation `#{request.method}'"
            when Class # a Rack::RPC::Operation subclass
              response.result = operator.new(request).execute
            else
              response.result = @server.__send__(operator, *request.params)
          end

        rescue ::TypeError => exception # FIXME
          if @server.respond_to?(:rack_type_error_handler)
            response.error = @server.rack_type_error_handler exception
          else
            response.error = JSONRPC::ClientError.new(:message => exception.to_s)
          end

        rescue ::NoMethodError => exception
          if @server.respond_to?(:rack_no_method_error_handler)
            response.error = @server.rack_no_method_error_handler exception
          else
            response.error = JSONRPC::NoMethodError.new(:message => exception.to_s)
          end

        rescue ::ArgumentError => exception
          if @server.respond_to?(:rack_argument_error_handler)
            response.error = @server.rack_argument_error_handler exception
          else
            response.error = JSONRPC::ArgumentError.new(:message => exception.to_s)
          end

        rescue ::Rack::RPC::Error => exception
          if @server.respond_to?(:rack_rpc_error_handler)
            response.error = @server.rack_rpc_error_handler exception
          else
            response.error = JSONRPC::Error.new(:message => exception.to_s,
                                              :code => exception.code,
                                              :data => exception.data)
          end
        rescue => exception
          if @server.respond_to?(:rack_error_handler)
            response.error = @server.rack_error_handler exception
          else
            Rack::RPC::Logger.log.error "INTERNAL ERROR #{exception}; backtrace: \n#{exception.backtrace.join("\n")}"
            response.error = JSONRPC::InternalError.new(:message => exception.to_s)
          end
        end
        response.to_hash.delete_if { |k, v| v.nil? }
      end
    end # Server

    ##
    # Base class for JSON-RPC objects.
    class Object
      OPTIONS = {}

      ##
      # @param  [String] input
      # @return [Object]
      def self.parse(input)
        self.new(JSON.parse(input))
      end

      ##
      # An arbitrary context associated with the object.
      #
      # @return [Object]
      attr_reader :context

      ##
      # @param  [Hash] options
      # @param  [Object] context
      #   an optional context to associate with the object
      def initialize(options = {}, context = nil)
        options = self.class.const_get(:OPTIONS).merge(options)
        options.each do |k, v|
          instance_variable_set("@#{k}", v)
        end
        @context = context if context
      end

      ##
      # @return [String]
      def to_json
        to_hash.delete_if { |k, v| v.nil? }.to_json
      end
    end # Object

    ##
    # JSON-RPC notification objects.
    class Notification < Object
      attr_accessor :version
      attr_accessor :method
      attr_accessor :params

      ##
      # @return [Boolean]
      def valid?
        true # TODO
      end

      ##
      # @return [Hash]
      def to_hash
        {
          :jsonrpc => (version || VERSION).to_s,
          :method  => method.to_s,
          :params  => params ? params.to_a : [], # NOTE: named arguments not supported
        }
      end
    end # Notification

    ##
    # JSON-RPC request objects.
    class Request < Notification
      attr_accessor :id

      ##
      # @return [Boolean]
      def valid?
        super && !id.nil?
      end

      ##
      # @return [Hash]
      def to_hash
        super.merge({
          :id => id,
        })
      end

      ##
      # @return [Array]
      def to_args
        # used from Operation#initialize
        params
      end
    end # Request

    ##
    # JSON-RPC response objects.
    class Response < Object
      attr_accessor :version
      attr_accessor :result
      attr_accessor :error
      attr_accessor :id

      ##
      # @return [Hash]
      def to_hash
        {
          :jsonrpc => (version || VERSION).to_s,
          :result  => result,
          :error   => error ? error.to_hash : nil,
          :id      => id,
        }
      end
    end # Response

    ##
    # JSON-RPC error objects.
    class Error < Object
      attr_accessor :code
      attr_accessor :message
      attr_accessor :data
      
      @@default_data_message = "Unknown Error"

      def self.set_default_data_message message
        @@default_data_message = message
      end

      ##
      # @return [Hash]
      def to_hash
        data = {:message => @@default_data_message} if data.nil? || data[:message].nil?
        {
          :code    => code.to_i,
          :message => message.to_s,
          :data    => data,
        }
      end
    end # Error

    class ParseError < Error
      OPTIONS = {:code => -32700, :message => "parse error"}
    end # ParseError

    class ClientError < Error
      OPTIONS = {:code => -32600, :message => "invalid request"}
    end # ClientError

    class NoMethodError < Error
      OPTIONS = {:code => -32601, :message => "undefined method"}
    end # NoMethodError

    class ArgumentError < Error
      OPTIONS = {:code => -32602, :message => "invalid arguments"}
    end # ArgumentError

    class InternalError < Error
      OPTIONS = {:code => -32603, :message => "internal error"}
    end # InternalError

    class ServerError < Error
      OPTIONS = {:code => -32000, :message => "server error"}
    end # ServerError
  end # JSONRPC
 end # Rack::RPC::Endpoint
