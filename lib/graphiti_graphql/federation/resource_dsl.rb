module GraphitiGraphQL
  module Federation
    module ResourceDSL
      class TypeProxy
        def initialize(caller, type_name)
          @caller = caller
          @type_name = type_name
        end

        def has_many(relationship_name, foreign_key: nil, magic: true, &blk)
          @caller.federated_has_many relationship_name,
            type: @type_name,
            foreign_key: foreign_key,
            magic: magic,
            &blk
        end
      end

      extend ActiveSupport::Concern

      class_methods do
        # Sugar around federated_has_many
        def federated_type(type_name)
          TypeProxy.new(self, type_name)
        end

        # Add to Graphiti::Resource config as normal
        # Helpful for inheritance + testing
        def federated_resources
          config[:federated_resources] ||= []
        end

        # NB - for external use, use federated_type("Type").has_many instead
        #
        # * Add to the list of external graphql-ruby types we need in schema
        # * Add a readable and filterable FK, without clobbering pre-existing
        def federated_has_many(name, type:, magic: true, foreign_key: nil, &blk)
          foreign_key ||= :"#{type.underscore}_id"
          resource = FederatedResource.new(type)
          federated_resources << resource
          resource.add_relationship(:has_many, name, self, foreign_key, &blk)

          return unless magic

          attribute = attributes.find { |name, config|
            name.to_sym == foreign_key &&
              !!config[:readable] &&
              !!config[:filterable]
          }
          has_filter = filters.key?(foreign_key)
          if !attribute && !has_filter
            attribute foreign_key, :integer,
              only: [:readable, :filterable],
              schema: false,
              readable: :gql?,
              filterable: :gql?
          elsif has_filter && !attribute
            prior = filters[foreign_key]
            attribute foreign_key, prior[:type],
              only: [:readable, :filterable],
              schema: false,
              readable: :gql?
            filters[foreign_key] = prior
          elsif attribute && !has_filter
            filter foreign_key, attribute[:type]
          end
        end

        # * Add to the list of external graphql-ruby types we need in schema
        # * Add a gql-specific attribute to the serializer that gives apollo
        #   the representation it needs.
        def federated_belongs_to(name, type: nil, foreign_key: nil, foreign_type: nil)
          type ||= name.to_s.camelize
          foreign_key ||= :"#{name.to_s.underscore}_id"
          resource = FederatedResource.new(type)
          federated_resources << resource
          resource.add_relationship(:belongs_to, name, self, foreign_key)

          foreign_type ||= :"#{name.to_s.underscore}_type" if resource.polymorphic?

          opts = {readable: :gql?, only: [:readable], schema: false}
          attribute name, :hash, opts do
            prc = self.class.attribute_blocks[foreign_key]
            fk = prc ? instance_eval(&prc) : @object.send(foreign_key)

            typename = type
            if resource.polymorphic?
              prc = self.class.attribute_blocks[foreign_type]
              ft = prc ? instance_eval(&prc) : @object.send(foreign_type)
              typename = type[ft]
            end

            if fk && typename.present?
              {__typename: typename, id: fk.to_s}
            end
          end
        end
      end

      # Certain attributes should only work in GQL context
      def gql?
        Graphiti.context[:graphql]
      end
    end
  end
end
