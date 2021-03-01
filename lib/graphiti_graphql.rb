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

Graphiti.class_eval do
  class << self
    attr_writer :graphql_schema
  end

  # TODO probably move these off of Graphiti
  def self.gql(query, variables)
    runner = ::GraphitiGraphQL::Runner.new
    runner.execute(query, variables, graphql_schema.schema)
  end

  def self.graphql_schema
    @graphql_schema ||= GraphitiGraphQL::Schema.generate
  end

  def self.graphql_schema?
    !!@graphql_schema
  end

  def self.graphql_schema!(entrypoint_resources = nil)
    @graphql_schema = GraphitiGraphQL::Schema.generate(entrypoint_resources)
  end
end

module GraphitiGraphQL
  class Error < StandardError; end

  class Configuration
    attr_accessor :schema_reloading

    def initialize
      self.schema_reloading = true
    end
  end

  class << self
    attr_accessor :schema_class
  end

  def self.config
    @config ||= Configuration.new
  end

  def self.define_context(&blk)
    @define_context = blk
  end

  def self.get_context
    obj = Graphiti.context[:object]
    if @define_context
      @define_context.call(obj)
    else
      {object: obj}
    end
  end
end

if defined?(::Rails)
  require "graphiti_graphql/engine"
end
