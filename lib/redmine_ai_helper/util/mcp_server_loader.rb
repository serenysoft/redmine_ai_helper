require "singleton"
require "json"
require "ruby_llm/mcp"

module RedmineAiHelper
  module Util
    # Loads MCP server definitions and generates dynamic agents.
    class McpServerLoader
      include Singleton
      include RedmineAiHelper::Logger

      # Executed once when Redmine starts up
      def self.load_all
        instance.generate_mcp_agent_classes
      end

      # Dynamically generate MCP agent subclasses from MCP server configuration
      def generate_mcp_agent_classes
        return if @agents_generated

        config_data = load_config
        mcp_servers = config_data["mcpServers"]
        return unless mcp_servers

        mcp_servers.each do |server_name, server_config|
          begin
            # Validate server configuration
            unless valid_server_config?(server_config)
              ai_helper_logger.warn "Invalid configuration for MCP server '#{server_name}': #{server_config}"
              next
            end

            # Generate class name
            class_name = "AiHelperMcp#{server_name.camelize}"

            # Avoid duplicate class definitions
            if Object.const_defined?(class_name)
              ai_helper_logger.debug "MCP agent class '#{class_name}' already exists, skipping"
              next
            end

            # Create dynamic subclass
            create_mcp_agent_subclass(class_name, server_name, server_config)

            ai_helper_logger.info "Successfully created MCP agent: #{class_name} for server '#{server_name}'"
          rescue => e
            ai_helper_logger.error "Error creating MCP agent for '#{server_name}': #{e.message}"
            ai_helper_logger.error e.backtrace.join("\n")
          end
        end

        @agents_generated = true
      end

      private

      # Load configuration file
      def load_config
        config_file_path = Rails.root.join("config", "ai_helper", "config.json")

        unless File.exist?(config_file_path)
          ai_helper_logger.warn "MCP config file not found: #{config_file_path}"
          return {}
        end

        JSON.parse(File.read(config_file_path))
      rescue JSON::ParserError => e
        ai_helper_logger.error "Invalid JSON in config file: #{e.message}"
        {}
      rescue => e
        ai_helper_logger.error "Error reading config file: #{e.message}"
        {}
      end

      # Validate server configuration
      def valid_server_config?(config)
        return false unless config.is_a?(Hash)

        # Infer type if missing (backward compatibility):
        # - If command/args present => stdio
        # - If url present => http (default over sse since we cannot auto-detect sse reliably)
        config["type"] ||= infer_server_type(config)

        return false unless config["type"]

        case config["type"]
        when "stdio"
          !!(config["command"] || config["args"])
        when "http", "sse"
          !!(config["url"] && valid_url?(config["url"]))
        else
          false
        end
      end

      # Infer server type from available keys (internal helper)
      def infer_server_type(config)
        return "stdio" if config["command"] || config["args"]
        return "http" if config["url"]
        nil
      end

      # Validate URL format
      def valid_url?(url)
        uri = URI.parse(url)
        %w[http https].include?(uri.scheme)
      rescue URI::InvalidURIError
        false
      end

      # Create MCP client
      def create_mcp_client(server_name, server_config, current_user: User.current)
        resolved_server_config = resolve_dynamic_auth_config(server_name, server_config, current_user: current_user)

        # Allow implicit type inference
        server_type = resolved_server_config["type"] || infer_server_type(resolved_server_config)
        case server_type
        when "stdio"
          create_stdio_client(server_name, resolved_server_config)
        when "http"
          create_http_client(server_name, resolved_server_config)
        when "sse"
          create_sse_client(server_name, resolved_server_config)
        else
          raise ArgumentError, "Unsupported MCP server type: #{resolved_server_config["type"] || "unknown"}"
        end
      end

      # Create STDIO MCP client using ruby_llm-mcp
      def create_stdio_client(server_name, server_config)
        RubyLLM::MCP.client(
          name: server_name,
          transport_type: :stdio,
          config: {
            command: build_command_string(server_config),
            env: server_config["env"] || {},
          }
        )
      end

      # Create HTTP MCP client using ruby_llm-mcp (streamable transport)
      def create_http_client(server_name, server_config)
        RubyLLM::MCP.client(
          name: server_name,
          transport_type: :streamable,
          config: {
            url: server_config["url"],
            headers: server_config["headers"] || {},
          }
        )
      end

      # Create SSE MCP client using ruby_llm-mcp
      def create_sse_client(server_name, server_config)
        RubyLLM::MCP.client(
          name: server_name,
          transport_type: :sse,
          config: {
            url: server_config["url"],
            headers: server_config["headers"] || {},
          }
        )
      end

      # Build command string
      def build_command_string(server_config)
        if server_config["command"] && server_config["args"]
          "#{server_config["command"]} #{server_config["args"].join(" ")}"
        elsif server_config["command"]
          server_config["command"]
        elsif server_config["args"]
          server_config["args"].join(" ")
        else
          raise ArgumentError, "Either 'command' or 'args' must be specified for stdio MCP server"
        end
      end

      # Resolve dynamic auth placeholders and apply Redmine defaults.
      # @param server_name [String] MCP server name
      # @param server_config [Hash] Original MCP server config
      # @param current_user [User, nil] Current user context
      # @return [Hash] Resolved MCP server config
      def resolve_dynamic_auth_config(server_name, server_config, current_user:)
        config = (server_config || {}).deep_dup
        api_key = current_user_api_key(current_user)

        if config["headers"].is_a?(Hash)
          config["headers"] = config["headers"].transform_values { |value| replace_dynamic_placeholders(value, api_key) }
        end

        if config["env"].is_a?(Hash)
          config["env"] = config["env"].transform_values { |value| replace_dynamic_placeholders(value, api_key) }
        end

        inject_redmine_api_key!(server_name, config, api_key)
        config
      end

      # Returns current user's API key, generating one if needed.
      # @param current_user [User, nil]
      # @return [String, nil]
      def current_user_api_key(current_user)
        return nil unless current_user&.logged?

        current_user.generate_api_key if current_user.api_key.blank?
        current_user.api_key
      rescue => e
        ai_helper_logger.warn "Failed to resolve current user API key: #{e.message}"
        nil
      end

      # Replace known API key placeholders with the resolved value.
      # @param value [Object]
      # @param api_key [String, nil]
      # @return [Object]
      def replace_dynamic_placeholders(value, api_key)
        return value unless value.is_a?(String)

        value.gsub(/\$\{current_user_api_key\}|\{\{current_user_api_key\}\}|__CURRENT_USER_API_KEY__/i, api_key.to_s)
      end

      # Inject default Redmine auth headers/envs for Redmine MCP servers.
      # @param server_name [String]
      # @param config [Hash]
      # @param api_key [String, nil]
      # @return [void]
      def inject_redmine_api_key!(server_name, config, api_key)
        return unless api_key.present?
        return unless server_name.to_s.downcase.include?("redmine")

        if config["url"]
          config["headers"] ||= {}
          config["headers"]["X-Redmine-API-Key"] ||= api_key
        end

        if config["command"] || config["args"] || config["type"] == "stdio"
          config["env"] ||= {}
          config["env"]["REDMINE_API_KEY"] ||= api_key
        end
      end

      # Dynamically create MCP agent subclass
      def create_mcp_agent_subclass(class_name, server_name, server_config)
        sub_agent_class = Class.new(RedmineAiHelper::BaseAgent) do
          @server_name = server_name
          @server_config = server_config

          class << self
            attr_reader :server_name, :server_config
          end

          define_method :role do
            # Use the same identifier as registration (class underscored), e.g. AiHelperMcpSlack -> ai_helper_mcp_slack
            self.class.name.split("::").last.underscore
          end

          define_method :name do
            class_name
          end

          define_method :to_s do
            class_name
          end

          define_method :enabled? do
            true
          end

          define_method :available_tool_classes do
            cache_key = User.current&.id || "anonymous"
            @cached_tool_classes ||= {}
            return @cached_tool_classes[cache_key] if @cached_tool_classes.key?(cache_key)

            @mcp_clients ||= {}
            mcp_client = @mcp_clients[cache_key] ||= RedmineAiHelper::Util::McpServerLoader.instance.send(
              :create_mcp_client,
              server_name,
              server_config,
              current_user: User.current,
            )

            @cached_tool_classes[cache_key] = RedmineAiHelper::Tools::McpTools.generate_tool_classes(
              mcp_server_name: server_name,
              mcp_client: mcp_client,
              cache_key: cache_key,
            )
          rescue => e
            ai_helper_logger.error "Error loading tools for MCP server '#{server_name}': #{e.message}"
            []
          end

          # Override available_tools to handle MCP tool instances
          # (MCP tools are RubyLLM::Tool instances, not classes)
          define_method :available_tools do
            available_tool_classes.map do |tool|
              {
                function: {
                  name: tool.name,
                  description: tool.description,
                },
              }
            end
          end

          define_method :backstory do
            # Cache backstory to avoid regeneration for the same MCP agent class
            return @cached_backstory if @cached_backstory

            # Generate backstory strictly from prompt template (no fallback)
            prompt = load_prompt("mcp_agent/backstory")
            base_backstory = prompt.format(server_name: server_name)

            tools_info = ""
            begin
              tools_list = available_tools
              if tools_list.is_a?(Array) && !tools_list.empty?
                tools_info += "\n\nAvailable tools (#{server_name}):\n"
                tools_list.each do |tool|
                  if tool.is_a?(Hash) && tool.dig(:function, :description)
                    description = tool.dig(:function, :description)
                    tools_info += "- #{description}\n"
                  end
                end
              else
                tools_info += "\n\nNo tools available at the moment for #{server_name}."
              end
            rescue => e
              # Log tool info retrieval errors but do not mask prompt issues
              ai_helper_logger.error "Error retrieving tools information for '#{server_name}': #{e.message}"
              raise
            end

            @cached_backstory = base_backstory + tools_info
          end

          # Set class name with singleton method
          define_singleton_method :name do
            class_name
          end

          define_singleton_method :to_s do
            class_name
          end
        end

        # Set as constant
        Object.const_set(class_name, sub_agent_class)

        # Register with BaseAgent
        RedmineAiHelper::BaseAgent.register_pending_dynamic_class(sub_agent_class, class_name)
      end
    end
  end
end
