require "active_support/core_ext/object/json"

require "graphql"
require "graphiti"
require "graphiti_graphql/version"
require "graphiti_graphql/graphiti_schema/wrapper"
require "graphiti_graphql/graphiti_schema/sideload"
require "graphiti_graphql/graphiti_schema/resource"
require "graphiti_graphql/errors"
require "graphiti_graphql/schema"
require "graphiti_graphql/runner"
require "graphiti_graphql/util"

module GraphitiGraphQL
  class Configuration
    attr_accessor :schema_reloading

    def initialize
      self.schema_reloading = true
    end

    def define_context(&blk)
      @define_context = blk
    end

    def get_context
      obj = Graphiti.context[:object]
      if @define_context
        @define_context.call(obj)
      else
        {object: obj}
      end
    end
  end

  module Runnable
    def gql(query, variables)
      runner = ::GraphitiGraphQL::Runner.new
      runner.execute(query, variables, GraphitiGraphQL.schemas.graphql)
    end
  end

  class SchemaProxy
    def graphql
      generated.schema
    end

    def graphiti
      generated.graphiti_schema
    end

    def generated
      @generated ||= GraphitiGraphQL::Schema.generate
    end

    def generate!(entrypoint_resources = nil)
      @generated = GraphitiGraphQL::Schema.generate(entrypoint_resources)
    end

    def generated?
      !!@generated
    end

    def clear!
      @generated = nil
    end
  end

  class << self
    attr_accessor :schema_class
  end

  def self.config
    @config ||= Configuration.new
  end

  def self.schemas
    @schemas ||= SchemaProxy.new
  end
end

Graphiti.extend(GraphitiGraphQL::Runnable)

if defined?(::Rails)
  require "graphiti_graphql/engine"
end
