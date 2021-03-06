module GraphitiGraphQL
  class Runner
    def execute(query_string, variables, schema)
      query = GraphQL::Query.new(schema, query_string, variables: variables)
      definition = query.document.definitions.first
      selection = definition.selections.first
      is_graphiti = schemas.generated.query_field?(selection.name)

      # Wrap *everything* in context, in case of federated request
      Util.with_gql_context do
        if is_graphiti
          resource_class = schemas.generated
            .resource_for_query_field(selection.name)
          run_query(schema, resource_class, selection, query)
        else
          schemas.graphql.execute query_string,
            variables: variables,
            context: GraphitiGraphQL.config.get_context
        end
      end
    end

    private

    def schemas
      GraphitiGraphQL.schemas
    end

    def run_query(schema, resource_class, selection, query)
      if (errors = collect_errors(schema, query)).any?
        {"errors" => errors.map(&:to_h)}
      else
        params = process_selection(selection, {}, query.variables.to_h)
        json = resource_class.all(params).as_graphql
        render(json, selection.name)
      end
    end

    def render(json, selection_name)
      payload = if find_one?(selection_name)
        {selection_name.to_sym => json.values[0][0]}
      else
        json
      end
      {data: payload}
    end

    def find_one?(selection_name)
      selection_name == selection_name.singularize
    end

    def collect_errors(schema, query)
      query.analysis_errors = schema.analysis_engine
        .analyze_query(query, query.analyzers || [])
      query.validation_errors + query.analysis_errors + query.context.errors
    end

    def find_entrypoint_schema_resource(entrypoint)
      schemas.generated.schema_resource_for_query_field(entrypoint)
    end

    def introspection_query?(query)
      query.document.definitions.first.selections.first.name == "__schema"
    end

    def find_resource_by_selection_name(name)
      schemas.graphiti.resources
        .find { |r| r.type == name.pluralize.underscore }
    end


    def schema_resource_for_selection(selection, parent_resource)
      if parent_resource
        parent_resource.related_resource(selection.name.underscore.to_sym)
      else
        find_entrypoint_schema_resource(selection.name)
      end
    end

    def process_selection(
      selection,
      params,
      variables_hash,
      parent_resource = nil,
      parent_name_chain = nil,
      fragment_jsonapi_type: nil
    )
      selection_name = selection.name.underscore

      pbt = false # polymorphic_belongs_to
      if parent_resource
        pbt = parent_resource.pbt?(selection_name.to_sym)
      end

      chained_name = nil
      if fragment_jsonapi_type
        selection_name = "on__#{fragment_jsonapi_type}--#{selection_name}"
      end

      if parent_resource
        chained_name = selection_name
        if parent_name_chain
          chained_name = [parent_name_chain, selection_name].join(".")
        end
      end

      if !pbt
        resource = schema_resource_for_selection(selection, parent_resource)
        gather_filters(params, selection, variables_hash, chained_name)
        gather_sorts(params, selection, variables_hash, chained_name)
        gather_pages(params, selection, variables_hash, chained_name)
      end

      params[:include] ||= []
      params[:include] << chained_name if chained_name

      fragments = selection.selections.select { |s|
        s.is_a?(GraphQL::Language::Nodes::InlineFragment)
      }
      non_fragments = selection.selections - fragments

      if pbt
        # Only id/_type possible here
        fields, extra_fields, sideload_selections = [], [], []
        fields = non_fragments.map { |s| s.name.underscore }
        # If fragments specified, these will get merged in later
        if fragments.empty?
          params[:fields][chained_name] = fields.join(",")
        end
      else
        fields, extra_fields, sideload_selections =
          gather_fields(non_fragments, resource, params, chained_name)

        sideload_selections.each do |sideload_selection|
          process_selection(sideload_selection, params, variables_hash, resource, chained_name)
        end
      end

      fragments.each do |fragment|
        resource_name = schemas.generated.type_registry[fragment.type.name][:resource]
        klass = schemas.graphiti.resources.find { |r| r.name == resource_name }
        _, _, fragment_sideload_selections = gather_fields fragment.selections,
          klass,
          params,
          nil, # no chaining supported here
          polymorphic_parent_data: [fields, extra_fields, sideload_selections]

        fragment_sideload_selections.each do |sideload_selection|
          fragment_jsonapi_type = klass.type
          process_selection(sideload_selection, params, variables_hash, klass, chained_name, fragment_jsonapi_type: fragment_jsonapi_type)
        end
      end

      params
    end

    def gather_fields(
      selections,
      resource,
      params,
      chained_name,
      polymorphic_parent_data: nil
    )
      fields, extra_fields, sideload_selections = [], [], []
      selections.each do |sel|
        selection_name = sel.name.underscore
        sideload = resource.sideloads[selection_name.to_sym]
        if sideload && !sideload.remote?
          sideload_selections << sel
        else
          field_name = sel.name.underscore
          if resource.extra_attributes[field_name.to_sym]
            extra_fields << field_name
          else
            fields << field_name
          end
        end
      end

      if polymorphic_parent_data
        fields |= polymorphic_parent_data[0]
        extra_fields |= polymorphic_parent_data[1]
        sideload_selections |= polymorphic_parent_data[2]
      end

      params[:fields] ||= {}
      params[:extra_fields] ||= {}
      if chained_name
        field_param_name = chained_name

        # If this is a polymorphic fragment subselection, the field is just the
        # jsonapi type, for simplicity. TODO: Won't work if double-listing
        last_chain = chained_name.split(".").last
        if last_chain.starts_with?("on__")
          field_param_name = last_chain.split("--")[1]
        end
        # Remove the special on__ flag from the chain, since not used for fields
        field_param_name = field_param_name.gsub(/on__.*--/, "")

        params[:fields][field_param_name.to_sym] = fields.join(",")
        if extra_fields.present?
          params[:extra_fields][field_param_name.to_sym] = extra_fields.join(",")
        end
      else
        params[:fields][resource.type.to_sym] = fields.join(",")
        if extra_fields.present?
          params[:extra_fields][resource.type.to_sym] = extra_fields.join(",")
        end
      end

      [fields, extra_fields, sideload_selections]
    end

    def gather_filters(params, selection, variable_hash, chained_name = nil)
      filters = {}.tap do |f|
        arg = selection.arguments.find { |arg| arg.name == "filter" }
        arg ||= selection.arguments.find { |arg| arg.name == "id" }

        if arg
          if arg.name == "filter"
            arg.children[0].arguments.each do |attr_arg|
              field_name = attr_arg.name.underscore
              filter_param_name = [chained_name, field_name].compact.join(".")

              attr_arg.value.arguments.each do |operator_arg|
                value = operator_arg.value
                if value.respond_to?(:name) # is a variable
                  value = variable_hash[operator_arg.value.name]
                end
                f[filter_param_name] = {operator_arg.name.underscore => value}
              end
            end
          else
            value = arg.value
            if value.respond_to?(:name) # is a variable
              value = variable_hash[arg.value.name]
            end
            f[:id] = {eq: value}
          end
        end
      end

      if filters
        params[:filter] ||= {}
        params[:filter].merge!(filters)
      end
    end

    def gather_sorts(params, selection, variable_hash, chained_name = nil)
      sorts = [].tap do |s|
        selection.arguments.each do |arg|
          if arg.name == "sort"
            value = if arg.value.respond_to?(:name) # is a variable
              variable_hash[arg.value.name].map(&:to_h)
            else
              arg.value.map(&:to_h)
            end
            jsonapi_values = value.map { |v|
              att = (v[:att] || v["att"]).underscore
              att = [chained_name, att].compact.join(".")
              if v["dir"] == "desc"
                att = "-#{att}"
              end
              att
            }

            s << jsonapi_values.join(",")
          end
        end
      end

      if sorts.present?
        params[:sort] = [params[:sort], sorts].compact.join(",")
      end
    end

    def gather_pages(params, selection, variable_hash, chained_name = nil)
      pages = {}.tap do |p|
        selection.arguments.each do |arg|
          if arg.name == "page"
            value = if arg.value.respond_to?(:name) # is a variable
              variable_hash[arg.value.name].to_h
            else
              arg.value.to_h
            end

            if chained_name
              value.each_pair do |k, v|
                p["#{chained_name}.#{k}"] = v
              end
            else
              p.merge!(value)
            end
          end
        end
      end

      if pages.present?
        params[:page] ||= {}
        params[:page].merge!(pages)
      end
    end
  end
end
