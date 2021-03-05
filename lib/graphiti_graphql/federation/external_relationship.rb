module GraphitiGraphQL
  module Federation
    class ExternalRelationship
      attr_reader :name, :local_resource_class, :foreign_key

      def initialize(kind, name, local_resource_class, foreign_key)
        @kind = kind
        @name = name
        @local_resource_class = local_resource_class
        @foreign_key = foreign_key
      end

      def has_many?
        @kind == :has_many
      end

      def belongs_to?
        @kind == :belongs_to
      end
    end
  end
end
