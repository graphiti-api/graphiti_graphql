require "bundler/setup"
require "pry"
require "active_model"
require "graphql"
require "graphiti_spec_helpers/rspec"
require "graphiti"
require "graphiti_graphql"

ENV["TEST"] = "true"

# Avoiding loading classes before we're ready
Graphiti::Resource.autolink = false
require "fixtures"
Graphiti.setup!

original_resources = Graphiti.resources

def run(query, variables = {})
  raw = Graphiti.gql(query, variables).deep_symbolize_keys
  raw.key?(:data) ? raw[:data] : raw
end

def schema!(entrypoints = nil)
  if ENV["TEST"] == "true"
    resources ||= Graphiti.resources.reject(&:abstract_class?)
    resources.reject! { |r| r.name.nil? }
    collected = []
    resources.reverse_each do |resource|
      collected << resource unless collected.find { |c| c.name == resource.name }
    end
    resources = collected
    Graphiti.instance_variable_set(:@resources, resources)
  end
  Graphiti.graphql_schema!(entrypoints)
end

def schema_type(name)
  json = JSON.parse(Graphiti.graphql_schema.to_json)
  json["data"]["__schema"]["types"].find { |t| t["name"] == name }
end

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.before do
    schema!
  end

  config.after do
    PORO::DB.clear
    GraphitiGraphQL.schema_class = nil
    GraphitiGraphQL.instance_variable_set(:@define_context, nil)
  end

  config.around do |e|
    test_context = Class.new {
      include Graphiti::Context
    }
    Graphiti.config.context_for_endpoint = ->(path, action) {
      test_context
    }
    begin
      e.run
      collected = []
      original_resources.each do |resource|
        collected << resource
      end
      Graphiti.instance_variable_set(:@resources, collected)
    ensure
      Graphiti.config.context_for_endpoint = nil
    end
  end
end
