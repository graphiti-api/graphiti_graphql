# GraphitiGraphql

GraphQL (and Apollo Federation) support for Graphiti. Serve traditional Rails JSON, JSON:API or GraphQL with the same codebase.

Currently read-only, but you can add your own Mutations [manually](#blending-with-graphql-ruby).

## Setup

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

That's it 🎉!

#### GraphiQL

You can add the GraphiQL editor to the project via [graphiql-rails](https://github.com/rmosolgo/graphiql-rails) as normal, but to save you the time here are the steps to make it work when Rails is running in API-only mode:

Add to the Gemfile:

```ruby
gem "graphiql-rails"
gem 'sprockets', '~> 3' # https://github.com/rmosolgo/graphiql-rails/issues/53
```

And then in `config/application.rb`:

```ruby
# *Uncomment* this line!
# require "sprockets/railtie"
```

## Usage

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

Add to the Gemfile

```ruby
gem "apollo-federation"
gem "graphql-batch"
```

And change the way we require `graphiti_graphql`:

```ruby
gem "graphiti_graphql", require: "graphiti_graphql/federation"
```

To create a federated relationship:

```ruby
# PositionResource
federated_belongs_to :employee
```

Or pass `type` and/or `foreign_key` to customize:

```ruby
# type here is the GraphQL Type
federated_belongs_to :employee, type: "MyEmployee", foreign_key: :emp_id
```

For `has_many` it's a slightly different syntax because we're adding the relationship to the ***remote** type:

```ruby
federated_type("Employee").has_many :positions # foreign_key: optional
```

Finally, `has_many` accepts the traditional `params` block that works as normal:

```ruby
federated_type("Employee").has_many :positions do
  params do |hash|
    hash[:filter][:active] = true
    hash[:sort] = "-title"
  end
end
```

Remember that any time you make a change that affects the schema, you will have to bounce your federation gateway. This is how Apollo Federation works when not in "managed" mode.

## Configuration

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
