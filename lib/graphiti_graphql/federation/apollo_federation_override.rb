# Hacky sack!
# All we're doing here is adding extras: [:lookahead] to the _entities field
# And passing to to the .resolve_reference method when arity is 3
# This way we can request only fields the user wants when resolving the reference
# Important because we blow up when a field is guarded, and the guard fails
ApolloFederation::EntitiesField::ClassMethods.module_eval do
  alias_method :define_entities_field_without_override, :define_entities_field
  def define_entities_field(*args)
    result = define_entities_field_without_override(*args)
    extras = fields["_entities"].extras
    extras |= [:lookahead]
    fields["_entities"].instance_variable_set(:@extras, extras)
    result
  end
end

module GraphitiGraphQL
  module Federation
    module EntitiesFieldOverride
      # accept the lookahead as argument
      def _entities(representations:, lookahead:)
        representations.map do |reference|
          typename = reference[:__typename]
          type = context.warden.get_type(typename)
          if type.nil? || type.kind != GraphQL::TypeKinds::OBJECT
            raise "The _entities resolver tried to load an entity for type \"#{typename}\"," \
                  " but no object type of that name was found in the schema"
          end

          type_class = type.is_a?(GraphQL::ObjectType) ? type.metadata[:type_class] : type
          if type_class.respond_to?(:resolve_reference)
            meth = type_class.method(:resolve_reference)
            # ** THIS IS OUR EDIT **
            result = if meth.arity == 3
              type_class.resolve_reference(reference, context, lookahead)
            else
              type_class.resolve_reference(reference, context)
            end
          else
            result = reference
          end

          context.schema.after_lazy(result) do |resolved_value|
            context[resolved_value] = type
            resolved_value
          end
        end
      end
    end
  end
end

ApolloFederation::EntitiesField.send :prepend,
  GraphitiGraphQL::Federation::EntitiesFieldOverride
