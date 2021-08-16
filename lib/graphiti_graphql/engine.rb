if ActiveSupport::Inflector.method(:inflections).arity == 0
  # Rails 3 does not take a language in inflections.
  ActiveSupport::Inflector.inflections do |inflect|
    inflect.acronym("GraphitiGraphQL")
  end
else
  ActiveSupport::Inflector.inflections(:en) do |inflect|
    inflect.acronym("GraphitiGraphQL")
  end
end

module GraphitiGraphQL
  class Engine < ::Rails::Engine
    isolate_namespace GraphitiGraphQL

    # Ensure error handling kicks in
    # Corresponding default in config/routes.rb
    config.graphiti.handled_exception_formats += [:json]

    def self.reloader_class
      case Rails::VERSION::MAJOR
      when 4 then ActionDispatch::Reloader
      when 5 then ActiveSupport::Reloader
      when 6 then ::Rails.application.reloader
      end
    end

    # In dev mode, resource classes are reloaded, and the new classes
    # don't match what's in Graphiti.resources. Make sure everything is
    # the most recent available.
    # Really this belongs in graphiti-rails but keeping isolated for now
    initializer "graphiti_graphql.reload_resources" do |app|
      ::GraphitiGraphQL::Engine.reloader_class.to_prepare do
        resources = []
        Graphiti.resources.each do |resource|
          next unless resource.name # remove
          latest_resource = if (latest = resource.name.safe_constantize)
            latest
          else
            resource
          end

          unless resources.find { |res| res.name == resource.name }
            resources << latest_resource
          end
        end
        Graphiti.instance_variable_set(:@resources, resources)
      end
    end

    initializer "graphiti_graphql.schema_reloading" do |app|
      # Only reload the schema if we ask for it
      # Some may want to avoid the performance penalty
      if GraphitiGraphQL.config.schema_reloading
        GraphitiGraphQL::Engine.reloader_class.to_prepare do
          # We want to reload the schema when classes change
          # But this way, you only pay the cost (time) when the GraphQL endpoint
          # is actually hit
          if GraphitiGraphQL.schemas.generated?
            GraphitiGraphQL.schemas.clear!
          end
        end
      end
    end

    initializer "graphiti_graphql.define_controller" do
        app_controller = GraphitiGraphQL.config.federation_application_controller || ::ApplicationController
        # rubocop:disable Lint/ConstantDefinitionInBlock(Standard)
        class GraphitiGraphQL::ExecutionController < app_controller
          register_exception Graphiti::Errors::UnreadableAttribute, message: true
          def execute
            params = request.params # avoid strong_parameters
            render json: Graphiti.gql(params[:query], params[:variables])
          end
        end
    end

    initializer "graphiti_graphql.federation" do
      if defined?(GraphitiGraphQL::Federation)
        GraphitiGraphQL::Federation.setup!
      end
    end
  end
end
