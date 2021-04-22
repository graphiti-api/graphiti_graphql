module GraphitiGraphQL
  module GraphitiSchema
    class Sideload
      attr_reader :config, :schema
      attr_accessor :name

      def initialize(schema, config)
        @config = config
        @schema = schema
      end

      def graphql_class_name
        if type == :polymorphic_belongs_to
          parent_resource.graphql_class_name
        else
          resource.graphql_class_name
        end
      end

      def to_many?
        [:has_many, :many_to_many].include?(type)
      end

      def type
        config[:type].to_sym
      end

      def description
        config[:description]
      end

      def resource_name
        config[:resource]
      end

      def resource
        schema.get_resource(resource_name)
      end

      def remote?
        resources = child_resources? ? child_resources : [resource]
        resources.any?(&:remote?)
      end

      def parent_resource
        schema.get_resource(config[:parent_resource])
      end

      def child_resources?
        !!config[:resources]
      end

      def child_resources
        config[:resources].map do |name|
          schema.get_resource(name)
        end
      end
    end
  end
end
