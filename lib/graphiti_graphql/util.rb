module GraphitiGraphQL
  class Util
    def self.with_gql_context
      original = Graphiti.context[:graphql]
      Graphiti.context[:graphql] = true
      yield
    ensure
      Graphiti.context[:graphql] = original
    end

    # Should probably be in graphiti itself
    def self.parse_sort(raw)
      if raw.is_a?(Array)
        sorts = []
        raw.each do |sort|
          sort = sort.symbolize_keys
          att = sort[:att].to_s.underscore
          att = "-#{att}" if [:desc, "desc"].include?(sort[:dir])
          sorts << att
        end
        sorts.join(",")
      else
        raw
      end
    end
  end
end