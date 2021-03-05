begin
  require "apollo-federation"
rescue LoadError
  raise "You must add the 'apollo-federation' gem to use GraphitiGraphQL federation"
end

begin
  require "graphql/batch"
rescue LoadError
  raise "You must add the 'graphql-batch' gem to use GraphitiGraphQL federation"
end

# We don't want to add these as dependencies,
# but do need to check things don't break
if Gem::Version.new(ApolloFederation::VERSION) >= Gem::Version.new("2.0.0")
  raise "graphiti_graphql federation is incompatible with apollo-federation >= 2"
end

if Gem::Version.new(GraphQL::Batch::VERSION) >= Gem::Version.new("1.0.0")
  raise "graphiti_graphql federation is incompatible with graphql-batch >= 1"
end

require "graphiti_graphql"
require "graphiti_graphql/federation/loaders/has_many"
require "graphiti_graphql/federation/loaders/belongs_to"
require "graphiti_graphql/federation/external_resource"
require "graphiti_graphql/federation/external_relationship"
require "graphiti_graphql/federation/resource_dsl"
require "graphiti_graphql/federation/apollo_federation_override"

module GraphitiGraphQL
  module Federation
    # * Extend Graphiti::Resource with federated_* macros
    # * Add apollo-federation modules to graphql-ruby base types
    # * Mark federation = true for checks down the line
    def self.setup!
      Graphiti::Resource.send(:include, ResourceDSL)
      schema = GraphitiGraphQL::Schema
      schema.base_field = Class.new(schema.base_field) do
        include ApolloFederation::Field
      end
      schema.base_object = Class.new(schema.base_object) do
        include ApolloFederation::Object
      end
      schema.base_object.field_class(schema.base_field)
      schema.base_interface = Module.new do
        include GraphQL::Schema::Interface
        include ApolloFederation::Interface
      end
      schema.base_interface.field_class(schema.base_field)
      GraphitiGraphQL::Schema.federation = true
    end
  end
end
