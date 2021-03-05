module GraphitiGraphQL
  module Federation
    module Loaders
      class BelongsTo < GraphQL::Batch::Loader
        def initialize(resource_class, fields)
          @resource_class = resource_class
          @fields = fields
        end

        def perform(ids)
          Util.with_gql_context do
            params = {filter: {id: {eq: ids.join(",")}}}
            params[:fields] = {@resource_class.type => @fields.join(",")}
            records = @resource_class.all(params).as_json[:data]
            map = records.index_by { |record| record[:id].to_s }
            ids.each { |id| fulfill(id, map[id]) }
          end
        end
      end
    end
  end
end
