lib = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "graphiti_graphql/version"

Gem::Specification.new do |spec|
  spec.name = "graphiti_graphql"
  spec.version = GraphitiGraphQL::VERSION
  spec.authors = ["Lee Richmond"]
  spec.email = ["lrichmond1@bloomberg.net"]

  spec.summary = "GraphQL support for Graphiti"
  spec.description = "GraphQL support for Graphiti"
  spec.homepage = "https://www.graphiti.dev"

  # spec.metadata["allowed_push_host"] = "TODO: Set to 'http://mygemserver.com'"

  spec.metadata["homepage_uri"] = spec.homepage
  # spec.metadata["source_code_uri"] = "TODO: Put your gem's public repo URL here."
  # spec.metadata["changelog_uri"] = "TODO: Put your gem's CHANGELOG.md URL here."

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(File.expand_path("..", __FILE__)) do
    `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "graphiti", "~> 1.3.2"
  spec.add_dependency "activesupport", ">= 4.1"
  spec.add_dependency "graphql", "~> 1.12"

  spec.add_development_dependency "pry"
  spec.add_development_dependency "pry-byebug"
  spec.add_development_dependency "graphql", "~> 1.12"
  spec.add_development_dependency "graphiti_spec_helpers"
  spec.add_development_dependency "activemodel", ">= 4.1"
  spec.add_development_dependency "bundler", "~> 2.0"
  spec.add_development_dependency "rake", "~> 10.0"
  spec.add_development_dependency "rspec", "~> 3.0"
  spec.add_development_dependency "standardrb"

  spec.add_development_dependency "apollo-federation", "~> 1.1"
  spec.add_development_dependency "graphql-batch", "~> 0.4"
end
