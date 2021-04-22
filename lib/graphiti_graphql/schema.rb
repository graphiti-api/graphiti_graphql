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
    attr_reader :query_fields

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
      graphiti_schema = GraphitiGraphQL::GraphitiSchema::Wrapper
        .new(Graphiti::Schema.generate)
      instance.graphiti_schema = graphiti_schema
      instance.schema = schema
      instance.apply_query(entrypoint_resources || entrypoints)
      instance
    end

    def self.resource_class_for_type(type_name)
      const_get "#{type_name}Resource".gsub("__", "")
    end

    def initialize
      @type_registry = {}
      @query_fields = {}
    end

    def apply_query(entries)
      query_type = generate_schema_query(entries)
      Federation::SchemaDecorator.decorate(self) if self.class.federation?

      # NB - don't call .query here of federation will break things
      if schema.instance_variable_get(:@query_object)
        schema.instance_variable_set(:@query_object, nil)
        schema.instance_variable_set(:@federation_query_object, nil)
      end
      schema.orphan_types(orphans(schema))
      schema.query(query_type)
      schema.query # Actually fires the federation code
    end

    def generate_schema_query(entrypoint_resources = nil)
      existing_query = schema.instance_variable_get(:@query)
      existing_query ||= schema.send(:find_inherited_value, :query)
      # NB - don't call graphql_schema.query here of federation will break things
      query_class = Class.new(existing_query || self.class.base_object)
      # NB MUST be Query or federation-ruby will break things
      query_class.graphql_name "Query"

      get_entrypoints(entrypoint_resources).each do |resource|
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

    def schema_resource_for_query_field(name)
      @query_fields[name.underscore.to_sym]
    end

    def query_field?(name)
      @query_fields.include?(name.underscore.to_sym)
    end

    # We can't just constantize the name from the schema
    # Because classes can be reopened and modified in tests (or elsewhere, in theory)
    def resource_for_query_field(name)
      schema_resource = @query_fields[name.underscore.to_sym]
      Graphiti.resources.find { |r| r.name == schema_resource.name }
    end

    private

    def generate_connection_type(resource, top_level: true)
      name = "#{resource.graphql_class_name}#{top_level ? "TopLevel" : ""}Connection"
      if registered = type_registry[name]
        return registered[:type]
      end

      type = type_registry[resource.graphql_class_name][:type]
      klass = Class.new(self.class.base_object)
      klass.graphql_name(name)
      klass.field :nodes,
        [type],
        "List #{resource.graphql_class_name(false).pluralize}",
        null: false
      if top_level
        klass.field :stats, generate_stat_class(resource), null: false
      end
      register(name, klass)
      klass
    end

    def add_index(query_class, resource)
      field_name = resource.graphql_entrypoint.to_s.underscore.to_sym
      field = query_class.field field_name,
        generate_connection_type(resource, top_level: true),
        null: false
      @query_fields[field_name] = resource
      define_arguments_for_sideload_field(field, resource)
    end

    def add_show(query_class, resource)
      field_name = resource.graphql_entrypoint.to_s.underscore.singularize.to_sym
      field = query_class.field field_name,
        type_registry[resource.graphql_class_name][:type],
        "Single #{resource.graphql_class_name(false).singularize}",
        null: false
      @query_fields[field_name] = resource
      define_arguments_for_sideload_field field,
        resource,
        top_level_single: true
    end

    def get_entrypoints(manually_specified)
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
      filter_graphql_name = "#{type_name}Filter#{filter_name.to_s.camelize(:lower)}"
      klass.graphql_name(filter_graphql_name)
      filter_config[:operators].each do |operator|
        canonical_graphiti_type = Graphiti::Types
          .name_for(filter_config[:type])
        type = GQL_TYPE_MAP[canonical_graphiti_type]
        required = !!filter_config[:required] && operator == "eq"

        if (allowlist = filter_config[:allow])
          type = define_allowlist_type(filter_graphql_name, allowlist)
        end

        type = [type] unless !!filter_config[:single]
        klass.argument operator, type, required: required
      end
      klass
    end

    def define_allowlist_type(filter_graphql_name, allowlist)
      name = "#{filter_graphql_name}Allow"
      if (registered = type_registry[name])
        return registered[:type]
      end
      klass = Class.new(GraphQL::Schema::Enum)
      klass.graphql_name(name)
      allowlist.each do |allowed|
        klass.value(allowed)
      end
      register(name, klass)
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

        gql_field_type = if sideload.to_many?
          generate_connection_type(sideload.resource, top_level: false)
        else
          gql_type
        end
        field_name = name.to_s.camelize(:lower)
        unless type_class.fields[field_name]
          field = type_class.field field_name.to_sym,
            gql_field_type,
            null: !sideload.to_many?,
            description: sideload.description

          # No sort/filter/paginate on belongs_to
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

      if resource.description
        klass.description(resource.description)
      end

      klass.field(:_type, String, null: false)
      resource.all_attributes.each do |name, config|
        if config[:readable]
          canonical_graphiti_type = Graphiti::Types.name_for(config[:type])
          gql_type = GQL_TYPE_MAP[canonical_graphiti_type.to_sym]
          gql_type = String if name == :id
          # Todo document we don't have the concept, but can build it
          is_nullable = !(name == :id)
          opts = {null: is_nullable}
          opts[:description] = config[:description] if config[:description]
          klass.field(name, gql_type, opts)
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

    def generate_stat_class(resource)
      klass = Class.new(self.class.base_object)
      klass.graphql_name "#{resource.graphql_class_name(false)}Stats"
      resource.stats.each_pair do |name, calculations|
        calc_class = generate_calc_class(resource, name, calculations)
        klass.field name, calc_class, null: false
      end
      klass
    end

    def generate_calc_class(resource, stat_name, calculations)
      klass = Class.new(self.class.base_object)
      klass.graphql_name "#{resource.graphql_class_name(false)}#{stat_name}Calculations"
      calculations.each do |calc|
        klass.field calc, Float, null: false
      end
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
