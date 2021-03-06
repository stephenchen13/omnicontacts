# This class contains the common behavior for middlewares
# implementing either versions of OAuth.
#
# Extending classes are required to implement
# the following methods:
# * request_authorization_from_user 
# * fetch_contatcs
module OmniContacts
  module Middleware
    class BaseOAuth

      include HTTPUtils

      attr_reader :ssl_ca_file

      def initialize app, options
        @app = app
        @listening_path = "/contacts/" + class_name
        @ssl_ca_file = options[:ssl_ca_file]
      end

      def class_name
        self.class.name.split('::').last.downcase
      end

      # Rack callback. It handles three cases:
      # * user visit middleware entry point. 
      #   In this case request_authorization_from_user is called
      # * user is redirected back to the application 
      #   from the authorization site. In this case the list
      #   of contacts is fetched and stored in the variables
      #   omnicontacts.contacts within the Rack env variable.
      #   Once that is done the next middleware component is called.
      # * user visits any other resource. In this case the request
      #   is simply forwarded to the next middleware component.
      def call env
        @env = env
        if env["PATH_INFO"] =~ /^#{@listening_path}\/?$/
          store_query_string
          handle_initial_request(get_query_params(env))
        elsif env["PATH_INFO"] =~ /^#{redirect_path}/
          setup_query_params
          handle_callback
        else
          @app.call(env)
        end
      end

      private

      def get_query_params(env)
        query_string_to_map(env["QUERY_STRING"])
      end
      
      def test_mode?
        IntegrationTest.instance.enabled
      end

      def handle_initial_request(additional_query_params)
        execute_and_rescue_exceptions do
          if test_mode?
            IntegrationTest.instance.mock_authorization_from_user(self)
          else
            request_authorization_from_user(additional_query_params)
          end
        end
      end

      def handle_callback
        execute_and_rescue_exceptions do
          @env["omnicontacts.contacts"] = if test_mode?
            IntegrationTest.instance.mock_fetch_contacts(self)
          else
            fetch_contacts
          end

          @env["omnicontacts.query_params"] ||= get_originator_query_params

          @app.call(@env)
        end
      end

      def get_originator_query_params
        query_params = query_string_to_map(@env["QUERY_STRING"])

        if state = query_params["state"]
          JSON.parse(decode(state))["qs"] || {}
        else
          {}
        end
      end

      #  This method rescues executes a block of code and
      #  rescue all exceptions. In case of an exception the 
      #  user is redirected to the failure endpoint.
      def execute_and_rescue_exceptions
        yield
      rescue AuthorizationError => e
        handle_error :not_authorized, e
      rescue ::Timeout::Error, ::Errno::ETIMEDOUT => e
        handle_error :timeout, e
      rescue ::RuntimeError => e
        handle_error :internal_error, e
      end

      def handle_error error_type, exception
        logger << ("Error #{error_type} while processing #{@env["PATH_INFO"]}: #{exception.message}") if logger
        [302, {"location" => "/contacts/failure?#{get_failure_query_string(error_message: error_type)}"}, []]
      end

      def get_failure_query_string(error_params)
        map = query_string_to_map(@env["QUERY_STRING"])
        map.delete("state")
        to_query_string map.merge(get_originator_query_params).merge(error_params)
      end

      def session
        raise "You must provide a session to use OmniContacts" unless @env["rack.session"]
        @env["rack.session"]
      end

      def logger
        @env["rack.errors"] if @env
      end

      def base_prop_name
        "omnicontacts." + class_name
      end

      def store_query_string
        session["#{base_prop_name}.query_string"] = @env["QUERY_STRING"]
      end

      def setup_query_params
        @env["omnicontacts.query_params"] = query_string_to_map(session["#{base_prop_name}.query_string"])
      end
    end
  end
end
