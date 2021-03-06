# GraphitiGraphql

GraphQL (and Apollo Federation) support for Graphiti. Serve traditional Rails JSON, JSON:API or GraphQL with the same codebase.

### Setup

Add to your `Gemfile`:

```rb
gem 'graphiti', ">= 1.2.32"
gem "graphiti_graphql"
```

Mount the engine:

```ruby
# config/routes.rb
Rails.application.routes.draw do
  scope path: ApplicationResource.endpoint_namespace, defaults: { format: :jsonapi } do
    # ... normal graphiti stuff ...

    mount GraphitiGraphQL::Engine, at: "/gql"
  end
end
```

For a default Graphiti app, you can now serve GraphQL by POSTing to `/api/v1/gql`.

#### Blending with graphql-ruby

Define your Schema and Type classes as normal. Then in an initializer:

```ruby
# config/initializers/graphiti.rb
GraphitiGraphQL.schema_class = MySchema
```

Your existing GraphQL endpoint will continue working as normal. But the GQL endpoint you mounted in `config/routes.rb` will now serve BOTH your existing schema AND your Graphiti-specific schema. Note these cannot (currently) be served side-by-side on under `query` within the *same* request.

By default the GraphQL context will be `Graphiti.context[:object]`, which is the controller being called. You might want to customize this so your existing graphql-ruby code continues to expect the same context:

```ruby
GraphitiGraphQL.define_context do |controller|
  { current_user: controller.current_user }
end
```

#### Adding Federation Support

```ruby
gem "apollo-federation"
gem "graphql-batch"
```

#### GraphiQL

```
# If you want the graphiql editor
gem "graphiql-rails"
gem 'sprockets', '~> 3' # https://github.com/rmosolgo/graphiql-rails/issues/53
# Uncomment "sprockets/railtie" in config/application.rb
```

### Configuration

#### Entrypoints

By default all Graphiti resources will expose their `index` and `show` functionality. IOW `EmployeeResource` now serves a list at `Query#employees` and a single employee at `Query#employee(id: 123)`. To limit the entrypoints:

```ruby
GraphitiGraphQL::Schema.entrypoints = [
  EmployeeResource
]
```

#### Schema Reloading

You may want to automatically regenerate the GQL schema when when Rails reloads your classes, or you may not want to pay that performance penalty. To turn off the automatic reloading:

```ruby
# config/initializers/graphiti.rb
GraphitiGraphQL.config.schema_reloading = false
```
