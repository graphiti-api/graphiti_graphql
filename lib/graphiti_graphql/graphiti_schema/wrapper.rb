module GraphitiGraphQL
  module GraphitiSchema
    class Wrapper
      attr_reader :schema

      def initialize(schema)
        @schema = schema
      end

      def get_resource(name)
        config = schema[:resources].find { |r| r[:name] == name }
        raise "Could not find resource #{name} in schema" unless config
        Resource.new(self, schema[:resources].find { |r| r[:name] == name })
      end

      def resources
        schema[:resources].map { |r| get_resource(r[:name]) }
      end
    end
  end
end
