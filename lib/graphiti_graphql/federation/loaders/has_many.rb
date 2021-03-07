module GraphitiGraphQL
  module Federation
    module Loaders
      class HasMany < GraphQL::Batch::Loader
        def initialize(federated_relationship, params)
          @federated_relationship = federated_relationship
          @resource_class = federated_relationship.local_resource_class
          @params = params
          @foreign_key = federated_relationship.foreign_key
        end

        def perform(ids)
          @params[:filter] ||= {}
          @params[:filter][@foreign_key] = {eq: ids.join(",")}

          @federated_relationship.params_block&.call(@params)

          if ids.length > 1 && @params[:page]
            raise Graphiti::Errors::UnsupportedPagination
          elsif !@params[:page]
            @params[:page] = {size: 999}
          end

          Util.with_gql_context do
            records = @resource_class.all(@params).as_json[:data]
            map = records.group_by { |record| record[@foreign_key].to_s}
            ids.each { |id| fulfill(id, (map[id] || [])) }
          end
        end
      end
    end
  end
end
