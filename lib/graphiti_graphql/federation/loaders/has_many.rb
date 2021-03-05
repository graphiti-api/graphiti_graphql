module GraphitiGraphQL
  module Federation
    module Loaders
      class HasMany < GraphQL::Batch::Loader
        def initialize(resource_class, params, foreign_key)
          @resource_class = resource_class
          @params = params
          @foreign_key = foreign_key
        end

        def perform(ids)
          @params[:filter] ||= {}
          @params[:filter][@foreign_key] = {eq: ids.join(",")}

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
