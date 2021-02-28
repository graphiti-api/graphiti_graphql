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

      # TODO some work here, dupes, refer back, etc
      def merge_remotes!
        resources.select(&:remote?).each do |resource|
          remote_schema = resource.fetch_remote_schema!
          remote_schema[:resources].each do |remote_config|
            unless resources.map(&:name).include?(remote_config[:name])
              remote_config[:name] = resource.name
              schema[:resources].reject! { |r| r[:name] == resource.name }
              schema[:resources] << remote_config
              schema
            end
          end
        end
      end
    end
  end
end
