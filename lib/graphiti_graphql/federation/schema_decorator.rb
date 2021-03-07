module GraphitiGraphQL
  module Federation
    class SchemaDecorator
      def self.decorate(schema)
        new(schema).decorate
      end

      def initialize(schema)
        @schema = schema
      end

      def decorate
        @schema.schema.send(:include, ApolloFederation::Schema)
        # NB if we add mutation support, make sure this is applied after
        @schema.schema.use(GraphQL::Batch)
        add_resolve_reference
        add_external_resources
      end

      # Add to all local resource types
      # This is if a remote federated resource belongs_to a local resource
      def add_resolve_reference
        @schema.type_registry.each_pair do |name, config|
          if config[:resource]
            local_type = config[:type]
            local_type.key(fields: "id") if local_type.respond_to?(:key)
            local_resource = Graphiti.resources
              .find { |r| r.name == config[:resource] }
            # TODO: maybe turn off the graphiti debug for these?
            local_type.define_singleton_method :resolve_reference do |reference, context, lookahead|
              Federation::Loaders::BelongsTo
                .for(local_resource, lookahead.selections.map(&:name))
                .load(reference[:id])
            end
          end
        end
      end

      def external_resources
        {}.tap do |externals|
          Graphiti.resources.each do |r|
            externals.merge!(r.config[:federated_resources] || {})
          end
        end
      end

      def type_registry
        @schema.type_registry
      end

      def add_external_resources
        each_external_resource do |klass, config|
          # TODO: only do it if field not already defined
          config.relationships.each_pair do |name, relationship|
            if relationship.has_many?
              define_federated_has_many(klass, relationship)
            elsif relationship.belongs_to?
              define_federated_belongs_to(config, relationship)
            end
          end
        end
      end

      # NB: test already registered bc 2 things have same relationship
      def each_external_resource
        external_resources.each_pair do |klass_name, config|
          pre_registered = !!type_registry[klass_name]
          external_klass = if pre_registered
            type_registry[klass_name][:type]
          else
            add_external_resource_type(klass_name)
          end

          yield external_klass, config
        end
      end

      def add_external_resource_type(klass_name)
        external_type = Class.new(@schema.class.base_object)
        external_type.graphql_name klass_name
        external_type.key(fields: "id")
        external_type.extend_type
        external_type.field :id, String, null: false, external: true
        external_type.class_eval do
          def self.resolve_reference(reference, _context, _lookup)
            reference
          end
        end
        # NB must be registered before processing relationships
        type_registry[klass_name] = {type: external_type}
        external_type
      end

      def define_federated_has_many(external_klass, relationship)
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

        @schema.send :define_arguments_for_sideload_field,
          field, @schema.graphiti_schema.get_resource(local_resource_name)
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

          Federation::Loaders::HasMany
            .for(relationship, params)
            .load(object[:id])
        end
      end

      def define_federated_belongs_to(external_resource_config, relationship)
        type_name = GraphitiSchema::Resource.gql_name(relationship.local_resource_class.name)
        local_type = type_registry[type_name][:type]

        # Todo maybe better way here
        interface = type_registry["I#{type_name}"]

        local_type = interface[:type] if interface
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
    end
  end
end
