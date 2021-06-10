module GraphitiGraphQL
  module Federation
    class FederatedResource
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
        @relationships[name] = FederatedRelationship
          .new(kind, name, local_resource_class, foreign_key)
        if blk
          @relationships[name].instance_eval(&blk)
        end
      end

      def polymorphic?
        @type_name.is_a?(Hash)
      end

      def klass_name
        if polymorphic?
          "I#{@relationships.keys[0].to_s.camelize}"
        else
          @type_name
        end
      end
    end
  end
end
