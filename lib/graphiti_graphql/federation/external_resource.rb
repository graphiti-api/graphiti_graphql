module GraphitiGraphQL
  module Federation
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
        foreign_key,
        &blk
      )
        @relationships[name] = ExternalRelationship
          .new(kind, name, local_resource_class, foreign_key)
        if blk
          @relationships[name].instance_eval(&blk)
        end
      end
    end
  end
end
