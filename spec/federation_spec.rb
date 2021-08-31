require "spec_helper"
require "graphiti_graphql/federation"

RSpec.describe GraphitiGraphQL::Federation do
  include_context "resource testing"
  let(:resource) do
    Class.new(PORO::EmployeeResource) do
      include GraphitiGraphQL::Federation
      def self.name
        "PORO::EmployeeResource"
      end
    end
  end

  let(:position_resource) do
    Class.new(PORO::PositionResource) do
      include GraphitiGraphQL::Federation
      def self.name
        "PORO::PositionResource"
      end
    end
  end

  before do
    @schema = GraphitiGraphQL::Schema
    @original_base_field = @schema.base_field
    @original_base_object = @schema.base_object
    @original_base_interface = @schema.base_interface
    GraphitiGraphQL::Federation.setup!
    schema!([resource])
  end

  after do
    @schema.base_field = @original_base_field
    @schema.base_object = @original_base_object
    @schema.base_interface = @original_base_interface
    GraphitiGraphQL::Schema.federation = false
  end

  def type_instance(type_name, object)
    type = GraphitiGraphQL.schemas.graphql.types[type_name]
    type.send(:new, object, {}) # third arg is context
  end

  let(:lookahead_selections) do
    ["last_name", "age"]
  end

  let(:lookahead) do
    selections = lookahead_selections.map { |s| double(name: s) }
    double(selections: selections)
  end

  context "when federating" do
    it "adds the key directive to all resource types" do
      type = GraphitiGraphQL.schemas.graphql.types["POROEmployee"]
      expect(type.to_graphql.metadata[:federation_directives]).to eq([
        {name: "key", arguments: [{name: "fields", values: "id"}]}
      ])
    end
  end

  describe ".federated_type(...).has_many" do
    it "defines the external type correctly" do
      resource.federated_type("OtherPosition").has_many :employees
      schema!([resource])
      type = GraphitiGraphQL.schemas.graphql.types["OtherPosition"]
      expect(type.graphql_name).to eq("OtherPosition")
      expect(type.to_graphql.metadata[:federation_directives]).to eq([
        {name: "key", arguments: [{name: "fields", values: "id"}]},
        {name: "extends", arguments: nil}
      ])
    end

    context "when passed field: false" do
      before do
        resource.federated_type("OtherPosition").has_many :employees, field: false
        schema!([resource])
      end

      it "does not define a readable field" do
        expect(resource.attributes[:other_position_id][:readable])
          .to eq(false)
      end

      it "does define a guarded filter" do
        expect(resource.attributes[:other_position_id][:filterable])
          .to eq(:gql?)
      end
    end

    context "when passed filter: false" do
      before do
        resource.federated_type("OtherPosition").has_many :employees, filter: false
        schema!([resource])
      end

      it "does not add a filter" do
        expect(resource.filters.keys).to_not include(:other_position_id)
      end

      it "does define a guarded readable field" do
        expect(resource.attributes[:other_position_id][:readable])
          .to eq(:gql?)
      end
    end

    context "when a corresponding readable attribute is already defined" do
      before do
        resource.attribute :other_position_id, :integer
      end

      it "is not overridden" do
        expect(resource).to_not receive(:attribute)
        expect(resource).to_not receive(:filter)
        resource.federated_type("OtherPosition").has_many :employees
      end
    end

    context "when a corresponding filter is already defined" do
      before do
        resource.filter :other_position_id, :integer
      end

      it "is not overridden" do
        prior = resource.filters[:other_position_id]
        resource.federated_type("OtherPosition").has_many :employees
        expect(resource.filters[:other_position_id]).to eq(prior)
      end

      it "does apply the readable attribute, with the same type" do
        resource.federated_type("OtherPosition").has_many :employees
        att = resource.attributes[:other_position_id]
        expect(att[:type]).to eq(:integer)
        expect(att[:readable]).to eq(:gql?)
        expect(att[:filterable]).to eq(true)
        expect(att[:only]).to eq([:readable, :filterable])
      end
    end

    context "when no corresponding attribute or filter is defined" do
      it "is defined by default" do
        resource.federated_type("OtherPosition").has_many :employees
        att = resource.attributes[:other_position_id]
        expect(att[:only]).to eq([:readable, :filterable])
        expect(att[:schema]).to eq(false)
        expect(att[:readable]).to eq(:gql?)
        expect(att[:writable]).to eq(false)
        expect(att[:sortable]).to eq(false)
        expect(att[:filterable]).to eq(:gql?)
        expect(att[:type]).to eq(:integer)
      end
    end

    context "when no corresponding filter is defined" do
      it "is defined by default" do
        resource.federated_type("OtherPosition").has_many :employees
        att = resource.attributes[:other_position_id]
        expect(att[:filterable]).to eq(:gql?)
      end
    end

    context "when default attribute and filter are applied" do
      before do
        resource.federated_type("OtherPosition").has_many :employees
        schema!([resource])
      end

      it "does not render them outside of gql context" do
        PORO::Employee.create(first_name: "Rene")
        json = resource.all.as_json[:data][0]
        expect(json).to_not have_key(:other_position_id)
      end

      it "does not allow filtering outside of the gql context" do
        expect {
          resource.all({filter: {other_position_id: 1}}).to_a
        }.to raise_error(Graphiti::Errors::InvalidAttributeAccess, /filter/)
      end

      context "and the serialization is overridden" do
        before do
          resource.attribute :other_position_id, :integer do
            @object.other_position_id + 10
          end
        end

        it "is respected" do
          PORO::Employee.create(other_position_id: 5)
          begin
            original = Graphiti.context[:graphql]
            Graphiti.context[:grapqhl] = true
            record = resource.all.as_json[:data][0]
            expect(record[:other_position_id]).to eq(15)
          ensure
            Graphiti.context[:grapqhl] = original
          end
        end
      end

      context "and the filter is overridden" do
        before do
          resource.filter :other_position_id, :integer, single: true do
            eq do |scope, value|
              scope[:conditions] ||= {}
              scope[:conditions][:other_position_id] = value + 10
              scope
            end
          end
        end

        it "is respected" do
          employee = PORO::Employee.create(id: rand(9999), other_position_id: 15)
          begin
            original = Graphiti.context[:graphql]
            Graphiti.context[:graphql] = true
            record = resource.all({
              fields: {employees: "id"},
              filter: {other_position_id: 5}
            }).as_json[:data][0]
            expect(record[:id]).to eq(employee.id.to_s)
          ensure
            Graphiti.context[:graphql] = original
          end
        end
      end

      context "and custom foreign key" do
        before do
          resource.federated_type("OtherPosition").has_many :employees,
            foreign_key: :other_pos_id
        end

        context "and the serialization is overridden" do
          before do
            resource.attribute :other_pos_id, :integer do
              @object.other_pos_id + 20
            end
          end

          it "is respected" do
            PORO::Employee.create(other_pos_id: 5)
            begin
              original = Graphiti.context[:graphql]
              Graphiti.context[:grapqhl] = true
              record = resource.all.as_json[:data][0]
              expect(record[:other_pos_id]).to eq(25)
            ensure
              Graphiti.context[:grapqhl] = original
            end
          end
        end

        context "and the filter is overridden" do
          before do
            resource.filter :other_pos_id, :integer, single: true do
              eq do |scope, value|
                scope[:conditions] ||= {}
                scope[:conditions][:other_pos_id] = value + 20
                scope
              end
            end
          end

          it "is respected" do
            employee = PORO::Employee.create(id: rand(9999), other_pos_id: 25)
            begin
              original = Graphiti.context[:graphql]
              Graphiti.context[:graphql] = true
              record = resource.all({
                fields: {employees: "id"},
                filter: {other_pos_id: 5}
              }).as_json[:data][0]
              expect(record[:id]).to eq(employee.id.to_s)
            ensure
              Graphiti.context[:graphql] = original
            end
          end
        end
      end
    end

    context "when multiple resources reference the same remote type" do
      xit "still works" do
        # TODO: it does work, but need to write this test
      end
    end

    describe "loading" do
      let!(:employee1) do
        PORO::Employee.create \
          id: rand(9999),
          other_position_id: rand(9999),
          other_pos_id: rand(9999),
          first_name: "A",
          last_name: "Z",
          age: 10
      end
      let!(:employee2) do
        PORO::Employee.create \
          id: rand(9999),
          other_position_id: rand(9999),
          other_pos_id: rand(9999),
          first_name: "B",
          last_name: "Y",
          age: 20
      end
      let!(:employee3) do
        PORO::Employee.create \
          id: rand(9999),
          other_position_id: employee2.other_position_id,
          other_pos_id: employee1.other_pos_id,
          first_name: "C",
          last_name: "X",
          age: 30
      end
      let!(:employee4) do
        PORO::Employee.create \
          id: rand(9999),
          other_position_id: employee1.other_position_id,
          other_pos_id: employee2.other_pos_id,
          first_name: "D",
          last_name: "W",
          age: 40
      end

      # TODO batch spec - + test dont query for too many fields (perf)

      # def execute(instance1, instance2, params = {})
      #   batch1 = nil
      #   batch2 = nil
      #   params[:lookahead] = lookahead unless params.empty?
      #   GraphQL::Batch.batch do
      #     if params.empty?
      #       batch1 = instance1.employees(lookahead: lookahead)
      #       batch2 = instance2.employees(lookahead: lookahead)
      #     else
      #       batch1 = instance1.employees(params)
      #       batch2 = instance2.employees(params)
      #     end
      #   end
      #   [batch1.value, batch2.value]
      # end

      describe "basic" do
        it "works" do
          resource.federated_type("OtherPosition").has_many :employees
          schema!([resource])

          json = run(%(
            query($representations:[_Any!]!) {
              _entities(representations:$representations) {
                ...on OtherPosition {
                  employees {
                    nodes {
                      id
                      _type
                      firstName
                      lastName
                      age
                    }
                  }
                }
              }
            }
          ), {
            "representations" => [
              {
                "__typename" => "OtherPosition",
                "id" => employee1.other_position_id.to_s
              },
              {
                "__typename" => "OtherPosition",
                "id" => employee2.other_position_id.to_s
              }
            ]
          })

          expect(json).to eq({
            _entities: [
              {
                employees: {
                  nodes: [
                    {
                      id: employee1.id.to_s,
                      _type: "employees",
                      firstName: "A",
                      lastName: "Z",
                      age: 10
                    },
                    {
                      id: employee4.id.to_s,
                      _type: "employees",
                      firstName: "D",
                      lastName: "W",
                      age: 40
                    }
                  ]
                }
              },
              {
                employees: {
                  nodes: [
                    {
                      id: employee2.id.to_s,
                      _type: "employees",
                      firstName: "B",
                      lastName: "Y",
                      age: 20
                    },
                    {
                      id: employee3.id.to_s,
                      _type: "employees",
                      firstName: "C",
                      lastName: "X",
                      age: 30
                    }
                  ]
                }
              }
            ]
          })
        end

        it "applies page size 999 so the relationship is not cut off" do
          resource.federated_type("OtherPosition").has_many :employees
          schema!([resource])

          expect(resource).to receive(:all).with(hash_including({
            page: {size: 999}
          })).and_call_original

          run(%(
            query($representations:[_Any!]!) {
              _entities(representations:$representations) {
                ...on OtherPosition {
                  employees {
                    nodes {
                      firstName
                    }
                  }
                }
              }
            }
          ), {
            "representations" => [
              {
                "__typename" => "OtherPosition",
                "id" => employee1.other_position_id.to_s
              },
              {
                "__typename" => "OtherPosition",
                "id" => employee2.other_position_id.to_s
              }
            ]
          })
        end

        context "when no data" do
          before do
            PORO::DB.data[:employees] = []
          end

          it "returns an empty array" do
            resource.federated_type("OtherPosition").has_many :employees
            schema!([resource])

            json = run(%(
              query($representations:[_Any!]!) {
                _entities(representations:$representations) {
                  ...on OtherPosition {
                    employees {
                      nodes {
                        firstName
                      }
                    }
                  }
                }
              }
            ), {
              "representations" => [
                {
                  "__typename" => "OtherPosition",
                  "id" => employee1.other_position_id.to_s
                },
                {
                  "__typename" => "OtherPosition",
                  "id" => employee2.other_position_id.to_s
                }
              ]
            })

            expect(json).to eq({
              _entities: [
                {employees: {nodes: []}},
                {employees: {nodes: []}}
              ]
            })
          end
        end

        context "when an attribute is guarded" do
          context "and the guard fails" do
            around do |e|
              ctx = OpenStruct.new(current_user: "default")
              Graphiti.with_context ctx do
                e.run
              end
            end

            context "and the field was requested" do
              it "raises error" do
                resource.federated_type("OtherPosition").has_many :employees
                schema!([resource])

                expect {
                  run(%(
                    query($representations:[_Any!]!) {
                      _entities(representations:$representations) {
                        ...on OtherPosition {
                          employees {
                            nodes {
                              salary
                            }
                          }
                        }
                      }
                    }
                  ), {
                    "representations" => [
                      {
                        "__typename" => "OtherPosition",
                        "id" => employee1.other_position_id.to_s
                      }
                    ]
                  })
                }.to raise_error(Graphiti::Errors::UnreadableAttribute, /salary/)
              end
            end

            context "and the field was not requested" do
              it "works as normal" do
                resource.federated_type("OtherPosition").has_many :employees
                schema!([resource])
                expect {
                  run(%(
                    query($representations:[_Any!]!) {
                      _entities(representations:$representations) {
                        ...on OtherPosition {
                          employees {
                            nodes {
                              firstName
                            }
                          }
                        }
                      }
                    }
                  ), {
                    "representations" => [
                      {
                        "__typename" => "OtherPosition",
                        "id" => employee1.other_position_id.to_s
                      }
                    ]
                  })
                }.to_not raise_error
              end
            end
          end

          context "and the guard succeeds" do
            around do |e|
              ctx = OpenStruct.new(current_user: "admin")
              Graphiti.with_context ctx do
                e.run
              end
            end

            context "and the field was requested" do
              it "works as normal" do
                resource.federated_type("OtherPosition").has_many :employees
                schema!([resource])

                json = run(%(
                  query($representations:[_Any!]!) {
                    _entities(representations:$representations) {
                      ...on OtherPosition {
                        employees {
                          nodes {
                            salary
                          }
                        }
                      }
                    }
                  }
                ), {
                  "representations" => [
                    {
                      "__typename" => "OtherPosition",
                      "id" => employee1.other_position_id.to_s
                    },
                    {
                      "__typename" => "OtherPosition",
                      "id" => employee2.other_position_id.to_s
                    }
                  ]
                })

                entities = json[:_entities]
                nodes = entities.map { |e| e[:employees][:nodes] }.flatten
                expect(nodes.map { |n| n[:salary] }).to eq([
                  100_000,
                  100_000,
                  100_000,
                  100_000
                ])
              end
            end
          end
        end

        context "when custom serialization logic" do
          before do
            resource.federated_type("OtherPosition").has_many :employees
            resource.attribute :last_name, :string do
              "FOO"
            end
            schema!([resource])
          end

          it "is honored" do
            json = run(%(
              query($representations:[_Any!]!) {
                _entities(representations:$representations) {
                  ...on OtherPosition {
                    employees {
                      nodes {
                        lastName
                      }
                    }
                  }
                }
              }
            ), {
              "representations" => [
                {
                  "__typename" => "OtherPosition",
                  "id" => employee1.other_position_id.to_s
                },
                {
                  "__typename" => "OtherPosition",
                  "id" => employee2.other_position_id.to_s
                }
              ]
            })

            entities = json[:_entities]
            nodes = entities.map { |e| e[:employees][:nodes] }.flatten
            expect(nodes).to eq([
              {lastName: "FOO"},
              {lastName: "FOO"},
              {lastName: "FOO"},
              {lastName: "FOO"}
            ])
          end
        end

        context "when the relationship name is multi-word" do
          before do
            resource.federated_type("OtherPosition")
              .has_many :exemplary_employees
            schema!([resource])
          end

          it "still works" do
            json = run(%(
              query($representations:[_Any!]!) {
                _entities(representations:$representations) {
                  ...on OtherPosition {
                    exemplaryEmployees {
                      nodes {
                        id
                      }
                    }
                  }
                }
              }
            ), {
              "representations" => [
                {
                  "__typename" => "OtherPosition",
                  "id" => employee1.other_position_id.to_s
                },
                {
                  "__typename" => "OtherPosition",
                  "id" => employee2.other_position_id.to_s
                }
              ]
            })

            entities = json[:_entities]
            nodes = entities.map { |e| e[:exemplaryEmployees][:nodes] }
            expect(nodes[0]).to eq([
              {id: employee1.id.to_s},
              {id: employee4.id.to_s}
            ])
            expect(nodes[1]).to eq([
              {id: employee2.id.to_s},
              {id: employee3.id.to_s}
            ])
          end
        end

        context "when custom foreign key" do
          it "works" do
            resource.federated_type("OtherPosition").has_many :employees,
              foreign_key: :other_pos_id
            schema!([resource])

            json = run(%(
              query($representations:[_Any!]!) {
                _entities(representations:$representations) {
                  ...on OtherPosition {
                    employees {
                      nodes {
                        id
                      }
                    }
                  }
                }
              }
            ), {
              "representations" => [
                {
                  "__typename" => "OtherPosition",
                  "id" => employee1.other_pos_id.to_s
                },
                {
                  "__typename" => "OtherPosition",
                  "id" => employee2.other_pos_id.to_s
                }
              ]
            })
            entities = json[:_entities]
            nodes = entities.map { |e| e[:employees][:nodes] }
            expect(nodes[0]).to eq([
              {id: employee1.id.to_s},
              {id: employee3.id.to_s}
            ])
            expect(nodes[1]).to eq([
              {id: employee2.id.to_s},
              {id: employee4.id.to_s}
            ])
          end
        end

        context "when foreign key has custom serialization" do
          before do
            resource.federated_type("OtherPosition").has_many :employees
            resource.attribute :other_position_id, :string do
              @object.other_pos_id
            end
            resource.filter :other_position_id, :integer do
              eq do |scope, value|
                scope[:conditions] ||= {}
                scope[:conditions][:other_pos_id] = value
                scope
              end
            end
          end

          it "works by referencing the serialized value" do
            schema!([resource])

            json = run(%(
              query($representations:[_Any!]!) {
                _entities(representations:$representations) {
                  ...on OtherPosition {
                    employees {
                      nodes {
                        id
                      }
                    }
                  }
                }
              }
            ), {
              "representations" => [
                {
                  "__typename" => "OtherPosition",
                  "id" => employee1.other_pos_id.to_s
                },
                {
                  "__typename" => "OtherPosition",
                  "id" => employee2.other_pos_id.to_s
                }
              ]
            })

            entities = json[:_entities]
            nodes = entities.map { |e| e[:employees][:nodes] }
            expect(nodes[0]).to eq([
              {id: employee1.id.to_s},
              {id: employee3.id.to_s}
            ])
            expect(nodes[1]).to eq([
              {id: employee2.id.to_s},
              {id: employee4.id.to_s}
            ])
          end

          context "and is an integer" do
            before do
              resource.federated_type("OtherPosition").has_many :employees
              resource.attribute :other_position_id, :integer do
                @object.other_pos_id
              end
              resource.filter :other_position_id, :integer do
                eq do |scope, value|
                  scope[:conditions] ||= {}
                  scope[:conditions][:other_pos_id] = value
                  scope
                end
              end
            end

            it "works by casting to a string" do
              schema!([resource])

              json = run(%(
                query($representations:[_Any!]!) {
                  _entities(representations:$representations) {
                    ...on OtherPosition {
                      employees {
                        nodes {
                          id
                        }
                      }
                    }
                  }
                }
              ), {
                "representations" => [
                  {
                    "__typename" => "OtherPosition",
                    "id" => employee1.other_pos_id.to_s
                  },
                  {
                    "__typename" => "OtherPosition",
                    "id" => employee2.other_pos_id.to_s
                  }
                ]
              })

              entities = json[:_entities]
              nodes = entities.map { |e| e[:employees][:nodes] }
              expect(nodes[0]).to eq([
                {id: employee1.id.to_s},
                {id: employee3.id.to_s}
              ])
              expect(nodes[1]).to eq([
                {id: employee2.id.to_s},
                {id: employee4.id.to_s}
              ])
            end
          end
        end

        context "when filtering" do
          it "works" do
            resource.federated_type("OtherPosition").has_many :employees
            schema!([resource])

            json = run(%(
              query($representations:[_Any!]!, $names: [String!]!) {
                _entities(representations:$representations) {
                  ...on OtherPosition {
                    employees(filter: {firstName: { eq: $names } }) {
                      nodes {
                        id
                      }
                    }
                  }
                }
              }
            ), {
              "representations" => [
                {
                  "__typename" => "OtherPosition",
                  "id" => employee1.other_position_id.to_s
                },
                {
                  "__typename" => "OtherPosition",
                  "id" => employee2.other_position_id.to_s
                }
              ],
              "names" => [
                employee1.first_name,
                employee3.first_name
              ]
            })

            entities = json[:_entities]
            nodes = entities.map { |e| e[:employees][:nodes] }
            expect(nodes[0]).to eq([{id: employee1.id.to_s}])
            expect(nodes[1]).to eq([{id: employee3.id.to_s}])
          end
        end

        context "when sorting" do
          it "works" do
            resource.federated_type("OtherPosition").has_many :employees
            schema!([resource])

            json = run(%(
              query($representations:[_Any!]!) {
                _entities(representations:$representations) {
                  ...on OtherPosition {
                    employees(sort: [{ att: firstName, dir: desc }]) {
                      nodes {
                        id
                      }
                    }
                  }
                }
              }
            ), {
              "representations" => [
                {
                  "__typename" => "OtherPosition",
                  "id" => employee1.other_position_id.to_s
                },
                {
                  "__typename" => "OtherPosition",
                  "id" => employee3.other_position_id.to_s
                }
              ]
            })

            entities = json[:_entities]
            nodes = entities.map { |e| e[:employees][:nodes] }
            expect(nodes[0]).to eq([
              {id: employee4.id.to_s},
              {id: employee1.id.to_s}
            ])
            expect(nodes[1]).to eq([
              {id: employee3.id.to_s},
              {id: employee2.id.to_s}
            ])
          end
        end

        context "when paginating" do
          context "when from a single parent node" do
            it "works" do
              resource.federated_type("OtherPosition").has_many :employees
              schema!([resource])

              json = run(%(
                query($representations:[_Any!]!) {
                  _entities(representations:$representations) {
                    ...on OtherPosition {
                      employees(page: { size: 1, number: 2 }) {
                        nodes {
                          id
                        }
                      }
                    }
                  }
                }
              ), {
                "representations" => [
                  {
                    "__typename" => "OtherPosition",
                    "id" => employee1.other_position_id.to_s
                  }
                ]
              })

              entities = json[:_entities]
              nodes = entities.map { |e| e[:employees][:nodes] }
              expect(nodes[0]).to eq([{id: employee4.id.to_s}])
            end

            context "via after" do
              it "works" do
                resource.federated_type("OtherPosition").has_many :employees
                schema!([resource])

                cursor = Base64.encode64({offset: 1}.to_json)
                json = run(%(
                  query($representations:[_Any!]!) {
                    _entities(representations:$representations) {
                      ...on OtherPosition {
                        employees(after: "#{cursor}") {
                          nodes {
                            id
                          }
                        }
                      }
                    }
                  }
                ), {
                  "representations" => [
                    {
                      "__typename" => "OtherPosition",
                      "id" => employee1.other_position_id.to_s
                    }
                  ]
                })
                nodes = json[:_entities][0][:employees][:nodes]
                expect(nodes.length).to eq(1)
                expect(nodes[0][:id]).to eq(employee4.id.to_s)
              end
            end

            context "via 'before'" do
              it "works" do
                resource.federated_type("OtherPosition").has_many :employees
                schema!([resource])

                cursor = Base64.encode64({offset: 2}.to_json)
                json = run(%(
                  query($representations:[_Any!]!) {
                    _entities(representations:$representations) {
                      ...on OtherPosition {
                        employees(before: "#{cursor}", page: { size: 1 }) {
                          nodes {
                            id
                          }
                        }
                      }
                    }
                  }
                ), {
                  "representations" => [
                    {
                      "__typename" => "OtherPosition",
                      "id" => employee1.other_position_id.to_s
                    }
                  ]
                })
                nodes = json[:_entities][0][:employees][:nodes]
                expect(nodes.length).to eq(1)
                expect(nodes[0][:id]).to eq(employee1.id.to_s)
              end
            end

            context "via 'first'" do
              it "works" do
                resource.federated_type("OtherPosition").has_many :employees
                schema!([resource])

                json = run(%(
                  query($representations:[_Any!]!) {
                    _entities(representations:$representations) {
                      ...on OtherPosition {
                        employees(first: 1) {
                          nodes {
                            id
                          }
                        }
                      }
                    }
                  }
                ), {
                  "representations" => [
                    {
                      "__typename" => "OtherPosition",
                      "id" => employee1.other_position_id.to_s
                    }
                  ]
                })
                nodes = json[:_entities][0][:employees][:nodes]
                expect(nodes.length).to eq(1)
                expect(nodes[0][:id]).to eq(employee1.id.to_s)
              end
            end
          end

          context "when from multiple parent nodes" do
            it "works" do
              resource.federated_type("OtherPosition").has_many :employees
              schema!([resource])

              expect {
                run(%(
                  query($representations:[_Any!]!) {
                    _entities(representations:$representations) {
                      ...on OtherPosition {
                        employees(page: { size: 1, number: 2 }) {
                          nodes {
                            id
                          }
                        }
                      }
                    }
                  }
                ), {
                  "representations" => [
                    {
                      "__typename" => "OtherPosition",
                      "id" => employee1.other_position_id.to_s
                    },
                    {
                      "__typename" => "OtherPosition",
                      "id" => employee3.other_position_id.to_s
                    }
                  ]
                })
              }.to raise_error(Graphiti::Errors::UnsupportedPagination)
            end
          end
        end

        context "when customizing with params block" do
          def perform(params = {})
            run(%(
              query($representations:[_Any!]!) {
                _entities(representations:$representations) {
                  ...on OtherPosition {
                    employees {
                      nodes {
                        lastName
                        age
                      }
                    }
                  }
                }
              }
            ), {
              "representations" => [
                {
                  "__typename" => "OtherPosition",
                  "id" => employee1.other_position_id.to_s
                },
                {
                  "__typename" => "OtherPosition",
                  "id" => employee3.other_position_id.to_s
                }
              ]
            })
          end

          def expected_position_ids
            [employee1.other_position_id, employee2.other_position_id]
          end

          it "already has foreign key and fields in params" do
            resource.federated_type("OtherPosition").has_many :employees do
              params do |hash|
                hash[:spy] = hash.deep_dup
              end
            end
            schema!([resource])
            expected = {
              fields: {employees: "last_name,age,other_position_id,_type"},
              filter: {
                other_position_id: {
                  eq: expected_position_ids.join(",")
                }
              }
            }
            expect(resource).to receive(:all)
              .with(hash_including(spy: expected)).and_call_original
            perform
          end

          context "when sorting" do
            before do
              resource.federated_type("OtherPosition").has_many :employees do
                params do |hash|
                  hash[:sort] = "-age"
                end
              end
              schema!([resource])
            end

            it "works" do
              expect(resource).to receive(:all)
                .with(hash_including(
                  filter: {
                    other_position_id: {
                      eq: expected_position_ids.join(",")
                    }
                  },
                  sort: "-age"
                ))
                .and_call_original
              json = perform
              entities = json[:_entities]
              nodes = entities.map { |e| e[:employees][:nodes] }
              expect(nodes[0].map { |n| n[:age] }).to eq([40, 10])
              expect(nodes[1].map { |n| n[:age] }).to eq([30, 20])
            end

            context "and also given runtime sort" do
              it "obeys the params block" do
                expect(resource).to receive(:all)
                  .with(hash_including(
                    filter: {
                      other_position_id: {
                        eq: expected_position_ids.join(",")
                      }
                    },
                    sort: "-age"
                  ))
                  .and_call_original

                json = run(%(
                  query($representations:[_Any!]!) {
                    _entities(representations:$representations) {
                      ...on OtherPosition {
                        employees(sort: [{ att: id, dir: asc }]) {
                          nodes {
                            lastName
                            age
                          }
                        }
                      }
                    }
                  }
                ), {
                  "representations" => [
                    {
                      "__typename" => "OtherPosition",
                      "id" => employee1.other_position_id.to_s
                    },
                    {
                      "__typename" => "OtherPosition",
                      "id" => employee3.other_position_id.to_s
                    }
                  ]
                })

                entities = json[:_entities]
                nodes = entities.map { |e| e[:employees][:nodes] }
                expect(nodes[0].map { |n| n[:age]}).to eq([40, 10])
                expect(nodes[1].map { |n| n[:age]}).to eq([30, 20])
              end
            end

            context "and also given runtime filter" do
              it "merges params" do
                expect(resource).to receive(:all)
                  .with(hash_including({
                    filter: {
                      age: {
                        eq: [20]
                      },
                      other_position_id: {
                        eq: expected_position_ids.join(",")
                      }
                    }
                  }))
                  .and_call_original

                json = run(%(
                  query($representations:[_Any!]!) {
                    _entities(representations:$representations) {
                      ...on OtherPosition {
                        employees(filter: { age: { eq: 20 } }) {
                          nodes {
                            lastName
                            age
                          }
                        }
                      }
                    }
                  }
                ), {
                  "representations" => [
                    {
                      "__typename" => "OtherPosition",
                      "id" => employee1.other_position_id.to_s
                    },
                    {
                      "__typename" => "OtherPosition",
                      "id" => employee3.other_position_id.to_s
                    }
                  ]
                })

                entities = json[:_entities]
                nodes = entities.map { |e| e[:employees][:nodes] }
                expect(nodes[0]).to eq([])
                expect(nodes[1].map { |n| n[:age] }).to eq([20])
              end
            end
          end

          context "when filtering" do
            before do
              resource.federated_type("OtherPosition").has_many :employees do
                params do |hash|
                  hash[:filter][:age] = {eq: [10, 20, 40]}
                end
              end
              schema!([resource])
            end

            it "works" do
              expect(resource).to receive(:all)
                .with(hash_including(
                  filter: {
                    other_position_id: {
                      eq: expected_position_ids.join(",")
                    },
                    age: {eq: [10, 20, 40]}
                  },
                ))
                .and_call_original

              json = run(%(
                query($representations:[_Any!]!) {
                  _entities(representations:$representations) {
                    ...on OtherPosition {
                      employees(filter: { age: { eq: [10, 20, 40] } }) {
                        nodes {
                          lastName
                          age
                        }
                      }
                    }
                  }
                }
              ), {
                "representations" => [
                  {
                    "__typename" => "OtherPosition",
                    "id" => employee1.other_position_id.to_s
                  },
                  {
                    "__typename" => "OtherPosition",
                    "id" => employee3.other_position_id.to_s
                  }
                ]
              })

              entities = json[:_entities]
              nodes = entities.map { |e| e[:employees][:nodes] }
              expect(nodes[0].map { |n| n[:age] }).to eq([10, 40])
              expect(nodes[1].map { |n| n[:age] }).to eq([20])
            end

            context "and also given runtime sort" do
              it "merges params" do
                expect(resource).to receive(:all)
                  .with(hash_including(
                    filter: {
                      other_position_id: {
                        eq: expected_position_ids.join(",")
                      },
                      age: {eq: [10,20,40]}
                    },
                    sort: "-age"
                  ))
                  .and_call_original

                json = run(%(
                  query($representations:[_Any!]!) {
                    _entities(representations:$representations) {
                      ...on OtherPosition {
                        employees(sort: [{ att: age, dir: desc }]) {
                          nodes {
                            lastName
                            age
                          }
                        }
                      }
                    }
                  }
                ), {
                  "representations" => [
                    {
                      "__typename" => "OtherPosition",
                      "id" => employee1.other_position_id.to_s
                    },
                    {
                      "__typename" => "OtherPosition",
                      "id" => employee3.other_position_id.to_s
                    }
                  ]
                })

                entities = json[:_entities]
                nodes = entities.map { |e| e[:employees][:nodes] }
                expect(nodes[0].map { |n| n[:age] }).to eq([40, 10])
                expect(nodes[1].map { |n| n[:age] }).to eq([20])
              end
            end

            context "and also given runtime filter" do
              context "that conflicts" do
                it "obeys the params block" do
                  expect(resource).to receive(:all)
                    .with(hash_including(
                      filter: {
                        other_position_id: {
                          eq: expected_position_ids.join(",")
                        },
                        age: {eq: [10, 20, 40]}
                      },
                    ))
                    .and_call_original

                  json = run(%(
                    query($representations:[_Any!]!) {
                      _entities(representations:$representations) {
                        ...on OtherPosition {
                          employees(filter: { age: { eq: 30 } }) {
                            nodes {
                              lastName
                              age
                            }
                          }
                        }
                      }
                    }
                  ), {
                    "representations" => [
                      {
                        "__typename" => "OtherPosition",
                        "id" => employee1.other_position_id.to_s
                      },
                      {
                        "__typename" => "OtherPosition",
                        "id" => employee3.other_position_id.to_s
                      }
                    ]
                  })

                  entities = json[:_entities]
                  nodes = entities.map { |e| e[:employees][:nodes] }
                  expect(nodes[0].map { |n| n[:age] }).to eq([10, 40])
                  expect(nodes[1].map { |n| n[:age] }).to eq([20])
                end
              end

              context "that does not conflict" do
                it "merges params" do
                  expect(resource).to receive(:all)
                    .with(hash_including(
                      filter: {
                        other_position_id: {
                          eq: expected_position_ids.join(",")
                        },
                        age: {eq: [10, 20, 40]},
                        id: {eq: [employee4.id, employee2.id]}
                      }
                    ))
                    .and_call_original

                  json = run(%(
                    query($representations:[_Any!]!) {
                      _entities(representations:$representations) {
                        ...on OtherPosition {
                          employees(filter: { id: { eq: [#{employee4.id}, #{employee2.id}] } }) {
                            nodes {
                              lastName
                              age
                            }
                          }
                        }
                      }
                    }
                  ), {
                    "representations" => [
                      {
                        "__typename" => "OtherPosition",
                        "id" => employee1.other_position_id.to_s
                      },
                      {
                        "__typename" => "OtherPosition",
                        "id" => employee3.other_position_id.to_s
                      }
                    ]
                  })

                  entities = json[:_entities]
                  nodes = entities.map { |e| e[:employees][:nodes] }
                  expect(nodes[0].map { |n| n[:age] }).to eq([40])
                  expect(nodes[1].map { |n| n[:age] }).to eq([20])
                end
              end
            end
          end

          context "when paginating" do
            before do
              resource.federated_type("OtherPosition").has_many :employees do
                params do |hash|
                  hash[:page] = {size: 1}
                end
              end
              schema!([resource])
            end

            it "works" do
              expect(resource).to receive(:all)
                .with(hash_including(
                  filter: {
                    other_position_id: {
                      eq: employee1.other_position_id.to_s
                    },
                  },
                  page: {size: 1}
                ))
                .and_call_original

              json = run(%(
                query($representations:[_Any!]!) {
                  _entities(representations:$representations) {
                    ...on OtherPosition {
                      employees {
                        nodes {
                          id
                        }
                      }
                    }
                  }
                }
              ), {
                "representations" => [
                  {
                    "__typename" => "OtherPosition",
                    "id" => employee1.other_position_id.to_s
                  }
                ]
              })

              entities = json[:_entities]
              nodes = entities.map { |e| e[:employees][:nodes] }
              expect(nodes).to eq([[{id: employee1.id.to_s}]])
            end
          end
        end
      end
    end

    context "when the resource is polymorphic" do
      let!(:employee1) do
        PORO::Employee.create
      end

      let!(:visa) do
        PORO::Visa.create(id: 1, employee_id: employee1.id, number: 1)
      end

      let!(:gold_visa) do
        PORO::GoldVisa.create(id: 2, employee_id: employee1.id, number: 2)
      end

      let!(:mastercard) do
        PORO::Mastercard.create(id: 3, employee_id: employee1.id, number: 3)
      end

      let(:visa_resource) do
        Class.new(resource) do
          primary_endpoint "/visas"
          self.model = PORO::Visa
          self.type = :visas
          def self.name
            "PORO::FederatedVisaResource"
          end
        end
      end

      let(:gold_visa_resource) do
        Class.new(resource) do
          primary_endpoint "/gold_visas"
          self.model = PORO::GoldVisa
          self.type = :gold_visas
          def self.name
            "PORO::FederatedGoldVisaResource"
          end
        end
      end

      let(:mastercard_resource) do
        Class.new(resource) do
          primary_endpoint "/mastercards"
          self.model = PORO::Mastercard
          self.type = :mastercards
          def self.name
            "PORO::FederatedMastercardResource"
          end
        end
      end

      let!(:resource) do
        resource = Class.new(PORO::ApplicationResource) {
          self.model = PORO::CreditCardResource
          self.type = :credit_cards
          def self.name
            "PORO::FederatedCreditCardResource"
          end
          federated_type("Employee").has_many :credit_cards
          def base_scope
            {type: [:visas, :gold_visas, :mastercards]}
          end
        }
        resource
      end

      let(:lookahead_selections) do
        ["number", "__typename", "id"]
      end

      before do
        resource.polymorphic = [
          visa_resource,
          gold_visa_resource,
          mastercard_resource
        ]
        schema!([resource])
      end

      it "can load" do
        json = run(%(
          query($representations:[_Any!]!) {
            _entities(representations:$representations) {
              ...on Employee {
                creditCards {
                  nodes {
                    __typename
                    _type
                    id
                  }
                }
              }
            }
          }
        ), {
          "representations" => [
            {
              "__typename" => "Employee",
              "id" => visa.employee_id.to_s
            }
          ]
        })

        entities = json[:_entities]
        expect(entities).to eq([
          {
            creditCards: {
              nodes: [
                {
                  __typename: "POROFederatedVisa",
                  _type: "visas",
                  id: "1"
                },
                {
                  __typename: "POROFederatedGoldVisa",
                  _type: "gold_visas",
                  id: "2"
                },
                {
                  __typename: "POROFederatedMastercard",
                  _type: "mastercards",
                  id: "3"
                }
              ]
            }
          }
        ])
      end
    end
  end

  describe "federated_belongs_to" do
    let!(:position) do
      PORO::Position.create \
        title: "foo",
        other_employee_id: rand(9999),
        other_emp_id: rand(9999)
    end

    it "automatically defines a reference attribute" do
      position_resource.federated_belongs_to :employee
      att = position_resource.attributes[:employee]
      expect(att[:readable]).to eq(:gql?)
      expect(att[:only]).to eq([:readable])
      expect(att[:schema]).to eq(false)
      expect(att[:writable]).to eq(false)
      expect(att[:sortable]).to eq(false)
      expect(att[:filterable]).to eq(false)
      expect(att[:type]).to eq(:hash)
    end

    it "can query the reference attribute" do
      position_resource.federated_belongs_to :other_emp
      schema!([position_resource])
      json = run(%(
        query {
          positions {
            nodes {
              otherEmp {
                __typename
                id
              }
            }
          }
        }
      ))
      expect(json).to eq({
        positions: {
          nodes: [{
            otherEmp: {
              __typename: "OtherEmp",
              id: position.other_emp_id.to_s
            }
          }]
        }
      })
    end

    it "cannot query the reference attribute when not in gql context" do
      position_resource.federated_belongs_to :other_emp
      schema!([position_resource])
      allow(Graphiti).to receive(:context) { {graphql: false} }
      json = run(%(
        query {
          positions {
            nodes {
              otherEmp {
                __typename
                id
              }
            }
          }
        }
      ))
      expect(json).to eq({positions: {nodes: [{}]}})
    end

    it "defines the external type correctly" do
      position_resource.federated_belongs_to :other_employee
      schema!([position_resource])
      type = GraphitiGraphQL.schemas.graphql.types["OtherEmployee"]
      expect(type.graphql_name).to eq("OtherEmployee")
      expect(type.to_graphql.metadata[:federation_directives]).to eq([
        {name: "key", arguments: [{name: "fields", values: "id"}]},
        {name: "extends", arguments: nil}
      ])
    end

    context "when nil foreign key" do
      # other_emp_id is nil
      let!(:position2) { PORO::Position.create(other_employee_id: rand(999)) }

      before do
        position_resource.federated_belongs_to :other_emp
        schema!([position_resource])
      end

      it "renders null" do
        json = run(%(
          query {
            positions {
              nodes {
                otherEmp {
                  __typename
                  id
                }
              }
            }
          }
        ))
        expect(json[:positions][:nodes][1][:otherEmp]).to be_nil
      end
    end

    context "with custom foreign key" do
      it "is correctly referenced" do
        allow_any_instance_of(PORO::Position).to receive(:my_fk) { 9876 }
        position_resource.federated_belongs_to :other_emp,
          foreign_key: :my_fk
        schema!([position_resource])
        json = run(%(
          query {
            positions {
              nodes {
                otherEmp {
                  __typename
                  id
                }
              }
            }
          }
        ))
        expect(json).to eq({
          positions: {
            nodes: [{
              otherEmp: {
                __typename: "OtherEmp",
                id: "9876"
              }
            }]
          }
        })
      end

      context "when local type foreign key has custom serialization" do
        before do
          position_resource.attribute :other_emp_id, :string do
            10_000
          end
          position_resource.federated_belongs_to :other_emp
          schema!([position_resource])
        end

        it "is correctly referenced" do
          json = run(%(
            query {
              positions {
                nodes {
                  otherEmp {
                    __typename
                    id
                  }
                }
              }
            }
          ))
          expect(json).to eq({
            positions: {
              nodes: [{
                otherEmp: {
                  __typename: "OtherEmp",
                  id: "10000"
                }
              }]
            }
          })
        end

        context "and is an integer" do
          before do
            position_resource.attribute :other_emp_id, :integer do
              10_000
            end
            schema!([position_resource])
          end

          it "is cast to a string in the reference" do
            json = run(%(
              query {
                positions {
                  nodes {
                    otherEmp {
                      __typename
                      id
                    }
                  }
                }
              }
            ))
            expect(json).to eq({
              positions: {
                nodes: [{
                  otherEmp: {
                    __typename: "OtherEmp",
                    id: "10000"
                  }
                }]
              }
            })
          end
        end
      end
    end

    context "with explicit external type name" do
      before do
        position_resource.federated_belongs_to :other_emp,
          type: "OtherType"
        schema!([position_resource])
      end

      it "is correctly referenced" do
        json = run(%(
          query {
            positions {
              nodes {
                otherEmp {
                  __typename
                  id
                }
              }
            }
          }
        ))
        expect(json).to eq({
          positions: {
            nodes: [{
              otherEmp: {
                __typename: "OtherType",
                id: position.other_emp_id.to_s
              }
            }]
          }
        })
      end
    end

    context "when there is also a remote resource" do
      before do
        position_resource.federated_belongs_to :other_emp
        position_resource.belongs_to :other_emp, remote: "http://test.com"
        schema!([position_resource])
      end

      it "still works, rendering the attribute not the relationship" do
        json = run(%(
          query {
            positions {
              nodes {
                otherEmp {
                  __typename
                  id
                }
              }
            }
          }
        ))
        expect(json).to eq({
          positions: {
            nodes: [{
              otherEmp: {__typename: "OtherEmp", id: position.other_emp_id.to_s}
            }]
          }
        })
      end
    end
  end

  describe "federated polymorphic belongs_to" do
    let(:note_resource) do
      Class.new(PORO::NoteResource) do
        include GraphitiGraphQL::Federation
        def self.name
          "PORO::NoteResource"
        end
      end
    end

    let(:department_resource) do
      Class.new(PORO::DepartmentResource) do
        include GraphitiGraphQL::Federation
        def self.name
          "PORO::DepartmentResource"
        end
      end
    end
  
    let!(:employee1) { PORO::Employee.create(first_name: "Jane") }
    let!(:employee2) { PORO::Employee.create(first_name: "June") }
    let!(:department) { PORO::Department.create(name: "dept") }

    let!(:note1) do
      PORO::Note.create \
        body: "foo",
        notable_id: employee2.id,
        n_id: employee1.id,
        notable_type: "E"
    end

    let!(:note2) do
      PORO::Note.create \
        body: "bar",
        notable_id: department.id,
        notable_type: "D"
    end
  
    it "can query the reference attribute" do
      note_resource.federated_belongs_to :notable,
        type: {"E" => "POROEmployee", "D" => "PORODepartment"}
      schema!([note_resource])
      json = run(%(
        query {
          notes {
            nodes {
              notable {
                __typename
                id
              }
            }
          }
        }
      ))
      expect(json).to eq({
        notes: {
          nodes: [
            {
              notable: {
                __typename: "POROEmployee",
                id: employee2.id.to_s
              }
            },
            {
              notable: {
                __typename: "PORODepartment",
                id: department.id.to_s
              }
            }
          ]
        }
      })
    end

    context "when given explicit foreign key" do
      before do
        note_resource.federated_belongs_to :notable,
          foreign_key: :n_id,
          type: {"E" => "POROEmployee", "D" => "PORODepartment"}
        schema!([note_resource])
      end

      it "renders correctly" do
        json = run(%(
          query {
            notes {
              nodes {
                notable {
                  __typename
                  id
                }
              }
            }
          }
        ))
        expect(json).to eq({
          notes: {
            nodes: [
              {
                notable: {
                  __typename: "POROEmployee",
                  id: employee1.id.to_s
                }
              },
              {
                notable: nil
              }
            ]
          }
        })
      end
    end

    context "when given explicit foreign type" do
      let!(:department2) { PORO::Department.create }

      let!(:note3) do
        PORO::Note.create \
          notable_id: department2.id,
          notable_type: "E",
          n_type: "D"
      end

      before do
        note_resource.federated_belongs_to :notable,
          foreign_type: :n_type,
          type: {"E" => "POROEmployee", "D" => "PORODepartment"}
        schema!([note_resource])
      end

      it "renders correctly" do
        json = run(%(
          query {
            notes {
              nodes {
                notable {
                  __typename
                  id
                }
              }
            }
          }
        ))
        expect(json).to eq({
          notes: {
            nodes: [
              {
                notable: nil
              },
              {
                notable: nil
              },
              notable: {
                __typename: "PORODepartment",
                id: department2.id.to_s
              }
            ]
          }
        })
      end
    end

    context "when foreign key is present, but not foreign type" do
      let!(:department2) { PORO::Department.create }
      let!(:note3) { PORO::Note.create(notable_id: department2.id) }

      before do
        note_resource.federated_belongs_to :notable,
          type: {"E" => "POROEmployee", "D" => "PORODepartment"}
        schema!([note_resource])
      end

      it "renders null" do
        json = run(%(
          query {
            notes {
              nodes {
                notable {
                  __typename
                  id
                }
              }
            }
          }
        ))
        expect(json[:notes][:nodes][2][:notable]).to be_nil
      end
    end
  end

  describe ".resolve_reference" do
    it "is defined as a local resource fetch for local resources" do
      id = rand(9999)
      employee = PORO::Employee.create(id: id)
      type = GraphitiGraphQL.schemas.graphql.types["POROEmployee"]
      batch = GraphQL::Batch.batch {
        type.resolve_reference({id: id.to_s}, {}, lookahead)
      }
      expect(batch[:id]).to eq(employee.id.to_s)
    end

    context "when the user selects specific fields" do
      let(:lookahead_selections) { ["last_name", "age"] }

      it "only queries/returns those fields" do
        id = rand(9999)
        employee = PORO::Employee
          .create(id: id, last_name: "Amy #{rand(9999)}", age: rand(99))
        type = GraphitiGraphQL.schemas.graphql.types["POROEmployee"]
        batch = GraphQL::Batch.batch {
          type.resolve_reference({id: id.to_s}, {}, lookahead)
        }
        expect(batch).to eq({
          id: employee.id.to_s,
          last_name: employee.last_name,
          age: employee.age
        })
      end
    end

    it "is not defined on non-resource types" do
      type = GraphitiGraphQL.schemas.graphql.types["Page"]
      expect(type).to_not respond_to(:resolve_reference)
    end

    it "is defined as a passthrough for remote resources" do
      position_resource.federated_belongs_to :other_employee
      schema!([position_resource])
      type = GraphitiGraphQL.schemas.graphql.types["OtherEmployee"]
      expect(type.resolve_reference({foo: "bar"}, {}, lookahead))
        .to eq({foo: "bar"})
    end

    context "when a field is serialized" do
      before do
        resource.attribute :last_name, :string do
          @object.last_name.upcase
        end
      end

      it "is respected" do
        id = rand(9999)
        employee = PORO::Employee
          .create(id: id, last_name: "Amy #{rand(9999)}")
        type = GraphitiGraphQL.schemas.graphql.types["POROEmployee"]
        batch = GraphQL::Batch.batch {
          type.resolve_reference({id: employee.id.to_s}, {}, lookahead)
        }
        expect(batch[:last_name]).to eq(employee.last_name.upcase)
      end
    end

    context "when a field is guarded" do
      context "and the guard fails" do
        around do |e|
          ctx = OpenStruct.new(current_user: "default")
          Graphiti.with_context ctx do
            e.run
          end
        end

        context "and the field was requested by the user" do
          let(:lookahead_selections) { ["first_name", "salary", "age"] }

          it "raises error" do
            employee = PORO::Employee.create(id: rand(9999))
            type = GraphitiGraphQL.schemas.graphql.types["POROEmployee"]
            expect {
              GraphQL::Batch.batch do
                type.resolve_reference({id: employee.id.to_s}, {}, lookahead)
              end
            }.to raise_error(Graphiti::Errors::UnreadableAttribute, /salary/)
          end
        end

        context "and the field was NOT requested by the user" do
          let(:lookahead_selections) { ["first_name", "age"] }

          it "does not raise error" do
            employee = PORO::Employee.create(id: rand(9999))
            type = GraphitiGraphQL.schemas.graphql.types["POROEmployee"]
            expect {
              GraphQL::Batch.batch do
                type.resolve_reference({id: employee.id.to_s}, {}, lookahead)
              end
            }.to_not raise_error
          end
        end
      end

      context "and the guard passes" do
        around do |e|
          ctx = OpenStruct.new(current_user: "admin")
          Graphiti.with_context ctx do
            e.run
          end
        end

        let(:lookahead_selections) { ["first_name", "salary", "age"] }

        it "works as normal, even when requested by the user" do
          employee = PORO::Employee.create(id: rand(9999))
          type = GraphitiGraphQL.schemas.graphql.types["POROEmployee"]
          batch = GraphQL::Batch.batch {
            type.resolve_reference({id: employee.id.to_s}, {}, lookahead)
          }
          expect(batch[:salary]).to eq(100_000)
        end
      end
    end

    context "when the primary key is serialized" do
      before do
        resource.attribute :id, :string do
          @object.last_name
        end
        resource.filter :id do
          eq do |scope, value|
            scope[:conditions] ||= {}
            scope[:conditions][:last_name] = value
            scope
          end
        end
      end

      it "is referenced for resolution" do
        id = rand(9999)
        employee = PORO::Employee
          .create(id: id, last_name: "Amy #{rand(9999)}")
        type = GraphitiGraphQL.schemas.graphql.types["POROEmployee"]
        batch = GraphQL::Batch.batch {
          type.resolve_reference({id: employee.last_name}, {}, lookahead)
        }
        expect(batch[:id]).to eq(employee.last_name)
        expect(batch[:last_name]).to eq(employee.last_name)
      end
    end
  end
end
