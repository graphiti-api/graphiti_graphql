module GraphitiGraphQL
  class Schema
    GQL_TYPE_MAP = {
      integer_id: String,
      string: String,
      uuid: String,
      integer: Integer,
      float: Float,
      boolean: GraphQL::Schema::Member::GraphQLTypeNames::Boolean,
      date: GraphQL::Types::ISO8601Date,
      datetime: GraphQL::Types::ISO8601DateTime,
      hash: GraphQL::Types::JSON,
      array: [GraphQL::Types::JSON],
      array_of_strings: [String],
      array_of_integers: [Integer],
      array_of_floats: [Float],
      array_of_dates: [GraphQL::Types::ISO8601Date],
      array_of_datetimes: [GraphQL::Types::ISO8601DateTime]
    }

    class BaseField < GraphQL::Schema::Field
    end

    class BaseObject < GraphQL::Schema::Object
    end

    module BaseInterface
      include GraphQL::Schema::Interface
    end

    class << self
      attr_accessor :entrypoints, :federation
      attr_writer :base_field, :base_object, :base_interface
    end

    attr_accessor :type_registry, :schema, :graphiti_schema

    def self.federation?
      !!@federation
    end

    def self.base_field
      @base_field || BaseField
    end

    def self.base_object
      @base_object || BaseObject
    end

    def self.base_interface
      @base_interface || BaseInterface
    end

    def self.generate(entrypoint_resources = nil)
      instance = new
      schema = Class.new(::GraphitiGraphQL.schema_class || GraphQL::Schema)

      if federation?
        schema.send(:include, ApolloFederation::Schema)
      end

      graphiti_schema = GraphitiGraphQL::GraphitiSchema::Wrapper
        .new(Graphiti::Schema.generate)
      # TODO: if we avoid this on federation, or remove altogether
      # Make sure we don't blow up
      # graphiti_schema.merge_remotes!

      entries = entrypoint_resources || entrypoints
      instance.apply_query(graphiti_schema, schema, entries)

      # NB if we add mutation support, make sure this is applied after
      if federation?
        schema.use GraphQL::Batch
      end
      instance.schema = schema
      instance.graphiti_schema = graphiti_schema
      instance
    end

    def self.resource_class_for_type(type_name)
      const_get "#{type_name}Resource".gsub("__", "")
    end

    def initialize
      @type_registry = {}
    end

    # TODO put this in a Federation::Schema module
    # Maybe even the External classes themselves?
    # TODO assign/assign_each
    def apply_federation(graphiti_schema, graphql_schema)
      type_registry.each_pair do |name, config|
        if config[:resource]
          local_type = config[:type]
          local_resource = Graphiti.resources
            .find { |r| r.name == config[:resource] }
          # TODO: maybe turn off the graphiti debug for these?
          local_type.define_singleton_method :resolve_reference do |reference, context, lookahead|
            Federation::BelongsToLoader
              .for(local_resource, lookahead.selections.map(&:name))
              .load(reference[:id])
          end
        end
      end

      # NB: test already registered bc 2 things have same relationship
      GraphitiGraphQL::Federation.external_resources.each_pair do |klass_name, config|
        pre_registered = !!type_registry[klass_name]
        external_klass = if pre_registered
          type_registry[klass_name][:type]
        else
          external_klass = Class.new(self.class.base_object)
          external_klass.graphql_name klass_name
          external_klass
        end

        unless pre_registered
          external_klass.key(fields: "id")
          external_klass.extend_type
          external_klass.field :id, String, null: false, external: true
          external_klass.class_eval do
            def self.resolve_reference(reference, _context, _lookup)
              reference
            end
          end
        end

        unless pre_registered
          # NB must be registered before processing rels
          type_registry[klass_name] = {type: external_klass}
        end

        # TODO: only do it if field not already defined
        config.relationships.each_pair do |name, relationship|
          if relationship.has_many?
            define_federated_has_many(graphiti_schema, external_klass, relationship)
          elsif relationship.belongs_to?
            define_federated_belongs_to(config, relationship)
          end
        end
      end
    end

    # TODO: refactor to not constantly pass schemas around
    def define_federated_has_many(graphiti_schema, external_klass, relationship)
      local_name = GraphitiGraphQL::GraphitiSchema::Resource
        .gql_name(relationship.local_resource_class.name)
      local_type = type_registry[local_name][:type]
      local_resource_name = type_registry[local_name][:resource]
      local_resource = Graphiti.resources.find { |r| r.name == local_resource_name }

      local_interface = type_registry["I#{local_name}"]
      best_type = local_interface ? local_interface[:type] : local_type

      field = external_klass.field relationship.name,
        [best_type],
        null: false,
        extras: [:lookahead]

      define_arguments_for_sideload_field(field, graphiti_schema.get_resource(local_resource_name))
      external_klass.define_method relationship.name do |lookahead:, **arguments|
        # TODO test params...do version of sort with array/symbol keys and plain string
        params = arguments.as_json
          .deep_transform_keys { |key| key.to_s.underscore.to_sym }
        selections = lookahead.selections.map(&:name)
        selections << relationship.foreign_key
        selections << :_type # polymorphism
        params[:fields] = {local_resource.type => selections.join(",")}

        if (sort = Util.parse_sort(params[:sort]))
          params[:sort] = sort
        end

        Federation::HasManyLoader
          .for(local_resource, params, relationship.foreign_key)
          .load(object[:id])
      end
    end

    def define_federated_belongs_to(external_resource_config, relationship)
      type_name = GraphitiSchema::Resource.gql_name(relationship.local_resource_class.name)
      local_type = type_registry[type_name][:type]

      # Todo maybe better way here
      interface = type_registry["I#{type_name}"]

      local_type = interface[:type] if interface
      local_resource_name = type_registry[type_name][:resource]
      local_resource_class = Graphiti.resources.find { |r| r.name == local_resource_name }

      local_types = [local_type]
      if interface
        local_types |= interface[:implementers]
      end

      local_types.each do |local|
        local.field relationship.name,
          type_registry[external_resource_config.type_name][:type], # todo need to define the type?
          null: true
      end
    end

    def apply_query(graphiti_schema, graphql_schema, entries)
      query_type = generate_schema_query(graphql_schema, graphiti_schema, entries)
      if self.class.federation?
        apply_federation(graphiti_schema, schema)
      end

      # NB - don't call .query here of federation will break things
      if graphql_schema.instance_variable_get(:@query_object)
        graphql_schema.instance_variable_set(:@query_object, nil)
        graphql_schema.instance_variable_set(:@federation_query_object, nil)
      end
      graphql_schema.orphan_types(orphans(graphql_schema))
      graphql_schema.query(query_type)
      graphql_schema.query # Actually fires the federation code
    end

    def generate_schema_query(graphql_schema, graphiti_schema, entrypoint_resources = nil)
      existing_query = graphql_schema.instance_variable_get(:@query) || graphql_schema.send(:find_inherited_value, :query)
      # NB - don't call graphql_schema.query here of federation will break things
      query_class = Class.new(existing_query || self.class.base_object)
      # NB MUST be Query or federation-ruby will break things
      query_class.graphql_name "Query"

      entrypoints(graphiti_schema, entrypoint_resources).each do |resource|
        next if resource.remote?
        generate_type(resource)

        add_index(query_class, resource)
        add_show(query_class, resource)
      end
      query_class
    end

    def orphans(graphql_schema)
      [].tap do |orphans|
        type_registry.keys.each do |type_name|
          unless graphql_schema.types.has_key?(type_name)
            klass = type_registry[type_name][:type]
            orphans << klass if klass.is_a?(Class)
          end
        end
      end
    end

    private

    def add_index(query_class, resource)
      field = query_class.field resource.graphql_entrypoint,
        [type_registry[resource.graphql_class_name][:type]],
        "List #{resource.graphql_class_name(false).pluralize}",
        null: false
      define_arguments_for_sideload_field(field, resource)
    end

    def add_show(query_class, resource)
      entrypoint = resource.graphql_entrypoint.to_s.singularize.to_sym
      field = query_class.field entrypoint,
        type_registry[resource.graphql_class_name][:type],
        "Single #{resource.graphql_class_name(false).singularize}",
        null: true
      define_arguments_for_sideload_field field,
        resource,
        top_level_single: true
    end

    def entrypoints(graphiti_schema, manually_specified)
      resources = graphiti_schema.resources
      if manually_specified
        resources = resources.select { |r|
          manually_specified.map(&:name).include?(r.name)
        }
      end
      resources
    end

    def generate_sort_att_type_for(resource)
      type_name = "#{resource.graphql_class_name(false)}SortAtt"
      if (registered = type_registry[type_name])
        return registered[:type]
      end
      klass = Class.new(GraphQL::Schema::Enum) {
        graphql_name(type_name)
      }
      resource.sorts.each_pair do |name, config|
        klass.value name.to_s.camelize(:lower), "Sort by #{name}"
      end
      register(type_name, klass, resource)
      klass
    end

    def generate_sort_type(resource)
      type_name = "#{resource.graphql_class_name(false)}Sort"
      if (registered = type_registry[type_name])
        return registered[:type]
      end
      att_type = generate_sort_att_type_for(resource)
      klass = Class.new(GraphQL::Schema::InputObject) {
        graphql_name type_name
        argument :att, att_type, required: true
        argument :dir, SortDirType, required: true
      }
      register(type_name, klass)
      klass
    end

    def define_arguments_for_sideload_field(field, resource, top_level_single: false)
      if top_level_single
        field.argument(:id, String, required: true)
      else
        unless resource.sorts.empty?
          sort_type = generate_sort_type(resource)
          field.argument :sort, [sort_type], required: false
        end
        field.argument :page, PageType, required: false

        unless resource.filters.empty?
          filter_type = generate_filter_type(field, resource)
          required = resource.filters.any? { |name, config| !!config[:required] }
          field.argument :filter, filter_type, required: required
        end
      end
    end

    def generate_filter_type(field, resource)
      type_name = "#{resource.graphql_class_name(false)}Filter"
      if (registered = type_registry[type_name])
        return registered[:type]
      end
      klass = Class.new(GraphQL::Schema::InputObject)
      klass.graphql_name type_name
      resource.filters.each_pair do |name, config|
        attr_type = generate_filter_attribute_type(type_name, name, config)
        klass.argument name.to_s.camelize(:lower),
          attr_type,
          required: !!config[:required]
      end
      register(type_name, klass)
      klass
    end

    # TODO guarded operators or otherwise whatever eq => nil is
    def generate_filter_attribute_type(type_name, filter_name, filter_config)
      klass = Class.new(GraphQL::Schema::InputObject)
      klass.graphql_name "#{type_name}Filter#{filter_name.to_s.camelize(:lower)}"
      filter_config[:operators].each do |operator|
        canonical_graphiti_type = Graphiti::Types
          .name_for(filter_config[:type])
        type = GQL_TYPE_MAP[canonical_graphiti_type]
        required = !!filter_config[:required] && operator == "eq"
        klass.argument operator, type, required: required
      end
      klass
    end

    def generate_resource_for_sideload(sideload)
      if sideload.type == :polymorphic_belongs_to
        unless registered?(sideload.parent_resource)
          generate_type(sideload.parent_resource)
        end
      else
        unless registered?(sideload.resource)
          generate_type(sideload.resource)
        end
      end
    end

    def add_relationships_to_type_class(type_class, resource, processed = [])
      type_name = resource.graphql_class_name(false)
      return if processed.include?(type_name)

      resource.sideloads.each_pair do |name, sideload|
        next if sideload.remote?
        generate_resource_for_sideload(sideload)

        gql_type = if sideload.type == :polymorphic_belongs_to
          interface_for_pbt(resource, sideload)
        else
          type_registry[sideload.graphql_class_name][:type]
        end

        gql_field_type = sideload.to_many? ? [gql_type] : gql_type
        field_name = name.to_s.camelize(:lower)
        unless type_class.fields[field_name]
          field = type_class.field field_name.to_sym,
            gql_field_type,
            null: !sideload.to_many?

          # No sort/filter/paginate on belongs_to
          # unless sideload.type.to_s.include?('belongs_to')
          unless sideload.type == :polymorphic_belongs_to
            define_arguments_for_sideload_field(field, sideload.resource)
          end
        end

        processed << type_name

        # For PBT, the relationships are only possible on fragments
        unless sideload.type == :polymorphic_belongs_to
          add_relationships_to_type_class(gql_type, sideload.resource, processed)
        end
      end
    end

    def generate_type(resource, implements = nil)
      return if resource.remote?
      return if registered?(resource)
      type_name = resource.graphql_class_name(false)

      # Define the interface
      klass = nil
      poly_parent = resource.polymorphic? && !implements

      if poly_parent
        type_name = "I#{type_name}"
        klass = Module.new
        klass.send(:include, self.class.base_interface)
        klass.definition_methods do
          # rubocop:disable Lint/NestedMethodDefinition(Standard)
          def resolve_type(object, context)
            GraphitiGraphQL.schemas.graphql.types[object[:__typename]]
          end
        end
      else
        klass = Class.new(self.class.base_object)
      end
      klass.graphql_name type_name

      if implements
        implement(klass, type_registry[implements])
      end

      if self.class.federation?
        klass.key fields: "id"
      end

      klass.field(:_type, String, null: false)
      resource.all_attributes.each do |name, config|
        if config[:readable]
          canonical_graphiti_type = Graphiti::Types.name_for(config[:type])
          gql_type = GQL_TYPE_MAP[canonical_graphiti_type.to_sym]
          gql_type = String if name == :id
          # Todo document we don't have the concept, but can build it
          is_nullable = !(name == :id)
          klass.field(name, gql_type, null: is_nullable)
        end
      end

      register(type_name, klass, resource, poly_parent)

      resource.sideloads.each_pair do |name, sideload|
        if sideload.type == :polymorphic_belongs_to
          sideload.child_resources.each do |child_resource|
            unless registered?(child_resource)
              generate_type(child_resource)
            end
          end
        else
          unless registered?(sideload.resource)
            generate_type(sideload.resource)
          end
        end
      end

      # Define the actual class that implements the interface
      if poly_parent
        canonical_name = resource.graphql_class_name(false)
        klass = Class.new(self.class.base_object)
        implement(klass, type_registry[type_name])
        klass.graphql_name canonical_name
        register(canonical_name, klass, resource)
      end

      if poly_parent
        resource.children.each do |child|
          if registered?(child)
            child_klass = type_registry[child.graphql_class_name][:type]
            child_klass.implements(type_registry[type_name][:type])
          else
            generate_type(child, type_name)
          end
        end
      end

      add_relationships_to_type_class(klass, resource)

      klass
    end

    def registered?(resource)
      name = resource.graphql_class_name(false)
      !!type_registry[name]
    end

    def register(name, klass, resource = nil, interface = nil)
      value = {type: klass}
      value[:resource] = resource.name if resource
      value[:jsonapi_type] = resource.type if resource
      if interface
        value[:interface] = true
        value[:implementers] = []
      end
      type_registry[name] = value
    end

    def implement(type_class, interface_config)
      type_class.implements(interface_config[:type])
      interface_config[:implementers] << type_class
    end

    # Define interface for polymorphic_belongs_to sideload
    # After defining, ensure child resources implement the interface
    def interface_for_pbt(resource, sideload)
      type_name = "#{resource.graphql_class_name}__#{sideload.name}"
      interface = type_registry[type_name]
      if !interface
        klass = Module.new
        klass.send :include, self.class.base_interface
        klass.field :id, String, null: false
        klass.field :_type, String, null: false
        klass.graphql_name type_name
        sideload.child_resources.each do |r|
          type_registry[r.graphql_class_name][:type].implements(klass)
        end
        register(type_name, klass)
        interface = klass
      end
      interface
    end

    class PageType < GraphQL::Schema::InputObject
      graphql_name "Page"
      argument :size, Int, required: false
      argument :number, Int, required: false
    end

    class SortDirType < GraphQL::Schema::Enum
      graphql_name "SortDir"
      value "asc", "Ascending"
      value "desc", "Descending"
    end
  end
end
