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

module GraphitiGraphQL
  module Federation
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

    class HasManyLoader < GraphQL::Batch::Loader
      def initialize(resource_class, params, foreign_key)
        @resource_class = resource_class
        @params = params
        @foreign_key = foreign_key
      end

      def perform(ids)
        @params[:filter] ||= {}
        @params[:filter][@foreign_key] = {eq: ids.join(",")}

        if ids.length > 1 && @params[:page]
          raise Graphiti::Errors::UnsupportedPagination
        elsif !@params[:page]
          @params[:page] = {size: 999}
        end

        Util.with_gql_context do
          records = @resource_class.all(@params).as_json[:data]
          fk = ->(record) { record[@foreign_key].to_s }
          map = records.group_by(&fk)
          ids.each do |id|
            fulfill(id, (map[id] || []))
          end
        end
      end
    end

    class BelongsToLoader < GraphQL::Batch::Loader
      def initialize(resource_class, fields)
        @resource_class = resource_class
        @fields = fields
      end

      def perform(ids)
        Util.with_gql_context do
          params = {filter: {id: {eq: ids.join(",")}}}
          params[:fields] = {@resource_class.type => @fields.join(",")}
          records = @resource_class.all(params).as_json[:data]
          pk = ->(record) { record[:id].to_s }
          map = records.index_by(&pk)
          ids.each { |id| fulfill(id, map[id]) }
        end
      end
    end

    class ExternalRelationship
      attr_reader :name, :local_resource_class, :foreign_key

      def initialize(kind, name, local_resource_class, foreign_key)
        @kind = kind
        @name = name
        @local_resource_class = local_resource_class
        @foreign_key = foreign_key
      end

      def has_many?
        @kind == :has_many
      end

      def belongs_to?
        @kind == :belongs_to
      end
    end

    class ExternalResource
      attr_reader :type_name, :relationships

      def initialize(type_name)
        @type_name = type_name
        @relationships = {}
      end

      def add_relationship(
        kind,
        name,
        local_resource_class,
        foreign_key
      )
        @relationships[name] = ExternalRelationship
          .new(kind, name, local_resource_class, foreign_key)
      end
    end

    class TypeProxy
      def initialize(caller, type_name)
        @caller = caller
        @type_name = type_name
      end

      def has_many(relationship_name, foreign_key: nil)
        @caller.federated_has_many relationship_name,
          type: @type_name,
          foreign_key: foreign_key
      end
    end

    module ResourceDSL
      extend ActiveSupport::Concern

      class_methods do
        def federated_type(type_name)
          TypeProxy.new(self, type_name)
        end

        def federated_resources
          config[:federated_resources] ||= {}
        end

        # TODO: raise error if belongs_to doesn't have corresponding filter (on schema gen)
        def federated_has_many(name, type:, foreign_key: nil)
          foreign_key ||= :"#{type.underscore}_id"
          resource = federated_resources[type] ||= ExternalResource.new(type)
          resource.add_relationship(:has_many, name, self, foreign_key)

          attribute = attributes.find { |name, config|
            name.to_sym == foreign_key && !!config[:readable] && !!config[:filterable]
          }
          has_filter = filters.key?(foreign_key)
          if !attribute && !has_filter
            attribute foreign_key, :integer,
              only: [:readable, :filterable],
              schema: false,
              readable: :gql?,
              filterable: :gql?
          elsif has_filter && !attribute
            prior = filters[foreign_key]
            attribute foreign_key, prior[:type],
              only: [:readable, :filterable],
              schema: false,
              readable: :gql?
            filters[foreign_key] = prior
          elsif attribute && !has_filter
            filter foreign_key, attribute[:type]
          end
        end

        def federated_belongs_to(name, type: nil, foreign_key: nil)
          type ||= name.to_s.camelize
          foreign_key ||= :"#{name.to_s.underscore}_id"
          resource = federated_resources[type] ||= ExternalResource.new(type)
          resource.add_relationship(:belongs_to, name, self, foreign_key)

          attribute name, :hash, readable: :gql?, only: [:readable], schema: false do
            prc = self.class.attribute_blocks[foreign_key]
            fk = prc ? instance_eval(&prc) : @object.send(foreign_key)
            {__typename: type, id: fk.to_s}
          end
        end
      end

      # Certain attributes should only work in GQL context
      def gql?
        Graphiti.context[:graphql]
      end
    end
  end
end

# Hacky sack!
# All we're doing here is adding extras: [:lookahead] to the _entities field
# And passing to to the .resolve_reference method when arity is 3
# This way we can request only fields the user wants when resolving the reference
# Important because we blow up when a field is guarded, and the guard fails
ApolloFederation::EntitiesField::ClassMethods.module_eval do
  alias_method :define_entities_field_without_override, :define_entities_field
  def define_entities_field(*args)
    result = define_entities_field_without_override(*args)
    extras = fields["_entities"].extras
    extras |= [:lookahead]
    fields["_entities"].instance_variable_set(:@extras, extras)
    result
  end
end

module EntitiesFieldOverride
  # accept the lookahead as argument
  def _entities(representations:, lookahead:)
    representations.map do |reference|
      typename = reference[:__typename]
      type = context.warden.get_type(typename)
      if type.nil? || type.kind != GraphQL::TypeKinds::OBJECT
        raise "The _entities resolver tried to load an entity for type \"#{typename}\"," \
              " but no object type of that name was found in the schema"
      end

      type_class = type.is_a?(GraphQL::ObjectType) ? type.metadata[:type_class] : type
      if type_class.respond_to?(:resolve_reference)
        meth = type_class.method(:resolve_reference)
        # ** THIS IS OUR EDIT **
        result = if meth.arity == 3
          type_class.resolve_reference(reference, context, lookahead)
        else
          type_class.resolve_reference(reference, context)
        end
      else
        result = reference
      end

      context.schema.after_lazy(result) do |resolved_value|
        context[resolved_value] = type
        resolved_value
      end
    end
  end
end
ApolloFederation::EntitiesField.send :prepend, EntitiesFieldOverride
