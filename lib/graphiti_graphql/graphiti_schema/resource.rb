module GraphitiGraphQL
  module GraphitiSchema
    class Resource
      attr_reader :schema, :config

      def self.gql_name(name)
        Graphiti::Util::Class.graphql_type_name(name)
      end

      def initialize(schema, config)
        @schema = schema
        @config = config
      end

      def graphql_class_name(allow_interface = true)
        class_name = self.class.gql_name(name)
        if allow_interface
          if polymorphic? && !children.map(&:name).include?(name)
            class_name = "I#{class_name}"
          end
        end
        class_name
      end

      def sideloads
        @sideloads ||= {}.tap do |sideloads|
          config[:relationships].each_pair do |k, v|
            sideload = Sideload.new(schema, v)
            sideload.name = k
            sideloads[k] = sideload
          end
        end
      end

      def related_resource(relationship_name)
        resource_name = relationships[relationship_name][:resource]
        schema.get_resource(resource_name)
      end

      def pbt?(name)
        relationships[name][:type] == "polymorphic_belongs_to"
      end

      def polymorphic?
        !!config[:polymorphic]
      end

      def children
        config[:children].map do |name|
          schema.get_resource(name)
        end
      end

      def remote_url
        config[:remote]
      end

      def description
        config[:description]
      end

      def remote?
        !!config[:remote]
      end

      def name
        config[:name]
      end

      def stats
        config[:stats]
      end

      def type
        config[:type]
      end

      def graphql_entrypoint
        config[:graphql_entrypoint]
      end

      def sorts
        config[:sorts]
      end

      def filters
        config[:filters]
      end

      def relationships
        config[:relationships]
      end

      def extra_attributes
        config[:extra_attributes]
      end

      def attributes
        config[:attributes]
      end

      def all_attributes
        attributes.merge(extra_attributes)
      end
    end
  end
end
