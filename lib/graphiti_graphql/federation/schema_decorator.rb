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
        add_federated_resources
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

      def federated_resources
        federated = []
        Graphiti.resources.each do |r|
          federated |= (r.config[:federated_resources] || [])
        end
        federated
      end

      def type_registry
        @schema.type_registry
      end

      def add_federated_resources
        each_federated_resource do |type_class, federated_resource|
          federated_resource.relationships.each_pair do |name, relationship|
            if relationship.has_many?
              define_federated_has_many(type_class, relationship)
            elsif relationship.belongs_to?
              define_federated_belongs_to(federated_resource, relationship)
            end
          end
        end
      end

      # NB: test already registered bc 2 things have same relationship
      def each_federated_resource
        federated_resources.each do |federated_resource|
          pre_registered = !!type_registry[federated_resource.type_name]
          type_class = if pre_registered
            type_registry[federated_resource.type_name][:type]
          elsif federated_resource.polymorphic?
            add_federated_resource_interface(federated_resource)
          else
            add_federated_resource_type(federated_resource.klass_name)
          end

          yield type_class, federated_resource
        end
      end

      def add_federated_resource_interface(federated_resource)
        interface = define_polymorphic_federated_resource_interface(federated_resource.klass_name)
        federated_resource.type_name.values.each do |name|
          add_federated_resource_type(name, interface: interface)
        end
        interface
      end

      def define_polymorphic_federated_resource_interface(klass_name)
        interface = Module.new
        interface.send(:include, @schema.class.base_interface)
        interface.graphql_name(klass_name)
        interface.field :id, String, null: false, external: true
        type_registry[klass_name] = {type: interface, interface: true}
        interface
      end

      def add_federated_resource_type(klass_name, interface: nil)
        federated_type = Class.new(@schema.class.base_object)
        federated_type.graphql_name klass_name
        federated_type.key(fields: "id")
        federated_type.extend_type
        federated_type.implements(interface) if interface
        federated_type.field :id, String, null: false, external: true
        federated_type.class_eval do
          def self.resolve_reference(reference, _context, _lookup)
            reference
          end
        end
        # NB must be registered before processing relationships
        type_registry[klass_name] = {type: federated_type}
        federated_type
      end

      def define_connection_type(name, type_class)
        name = "#{name}FederatedConnection"
        if (registered = type_registry[name])
          return registered[:type]
        end

        klass = Class.new(@schema.class.base_object)
        klass.graphql_name(name)
        klass.field :nodes,
          [type_class],
          null: false,
          extras: [:lookahead]
        @schema.send :register, name, klass
        klass
      end

      def define_federated_has_many(type_class, relationship)
        local_name = GraphitiGraphQL::GraphitiSchema::Resource
          .gql_name(relationship.local_resource_class.name)
        local_type = type_registry[local_name][:type]
        local_resource_name = type_registry[local_name][:resource]
        local_resource = Graphiti.resources.find { |r| r.name == local_resource_name }

        local_interface = type_registry["I#{local_name}"]
        best_type = local_interface ? local_interface[:type] : local_type

        connection_type = define_connection_type(local_name, best_type)

        field = type_class.field relationship.name,
          connection_type,
          null: false,
          connection: false
        @schema.send :define_arguments_for_sideload_field,
          field, @schema.graphiti_schema.get_resource(local_resource_name)

        type_class.define_method relationship.name do |**arguments|
          {data: object, arguments: arguments}
        end
        connection_type.define_method :nodes do |lookahead:, **arguments|
          params = object[:arguments].as_json
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
            .load(object[:data][:id])
        end
      end

      def define_federated_belongs_to(federated_resource, relationship)
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
            type_registry[federated_resource.klass_name][:type],
            null: true
        end
      end
    end
  end
end
