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

      def execute(instance1, instance2, params = {})
        batch1 = nil
        batch2 = nil
        params[:lookahead] = lookahead unless params.empty?
        GraphQL::Batch.batch do
          if params.empty?
            batch1 = instance1.employees(lookahead: lookahead)
            batch2 = instance2.employees(lookahead: lookahead)
          else
            batch1 = instance1.employees(params)
            batch2 = instance2.employees(params)
          end
        end
        [batch1.value, batch2.value]
      end

      describe "basic" do
        it "works" do
          resource.federated_type("OtherPosition").has_many :employees
          schema!([resource])
          instance1 = type_instance "OtherPosition",
            {id: employee1.other_position_id.to_s}
          instance2 = type_instance "OtherPosition",
            {id: employee2.other_position_id.to_s}
          batch1, batch2 = execute(instance1, instance2)
          # extra fields are fine, will be stripped by gql-ruby
          # We just limit fields to avoid auth issues / improve perf
          # In fact, we want to ensure the FK comes back so it can
          # be used in the dataloader
          expect(batch1).to eq([
            {
              id: employee1.id.to_s,
              _type: "employees",
              age: 10,
              last_name: "Z",
              other_position_id: employee1.other_position_id
            },
            {
              id: employee4.id.to_s,
              _type: "employees",
              age: 40,
              last_name: "W",
              other_position_id: employee4.other_position_id
            }
          ])
          expect(batch2).to eq([
            {
              id: employee2.id.to_s,
              _type: "employees",
              age: 20,
              last_name: "Y",
              other_position_id: employee2.other_position_id
            },
            {
              id: employee3.id.to_s,
              _type: "employees",
              age: 30,
              last_name: "X",
              other_position_id: employee3.other_position_id
            }
          ])
        end

        it "applies page size 999 so the relationship is not cut off" do
          resource.federated_type("OtherPosition").has_many :employees
          schema!([resource])
          instance1 = type_instance "OtherPosition",
            {id: employee1.other_position_id.to_s}
          instance2 = type_instance "OtherPosition",
            {id: employee2.other_position_id.to_s}
          expect(resource).to receive(:all).with(hash_including({
            page: {size: 999}
          })).and_call_original
          execute(instance1, instance2)
        end

        context "when no data" do
          before do
            PORO::DB.data[:employees] = []
          end

          it "returns an empty array" do
            resource.federated_type("OtherPosition").has_many :employees
            schema!([resource])
            instance1 = type_instance "OtherPosition",
              {id: employee1.other_position_id.to_s}
            instance2 = type_instance "OtherPosition",
              {id: employee2.other_position_id.to_s}
            batch1, batch2 = execute(instance1, instance2)
            expect(batch1).to eq([])
            expect(batch2).to eq([])
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
              let(:lookahead_selections) { ["first_name", "salary", "age"] }

              it "raises error" do
                resource.federated_type("OtherPosition").has_many :employees
                schema!([resource])
                instance1 = type_instance "OtherPosition",
                  {id: employee1.other_position_id.to_s}
                instance2 = type_instance "OtherPosition",
                  {id: employee2.other_position_id.to_s}
                expect {
                  execute(instance1, instance2)
                }.to raise_error(Graphiti::Errors::UnreadableAttribute, /salary/)
              end
            end

            context "and the field was not requested" do
              let(:lookahead_selections) { ["first_name", "age"] }

              it "works as normal" do
                resource.federated_type("OtherPosition").has_many :employees
                schema!([resource])
                instance1 = type_instance "OtherPosition",
                  {id: employee1.other_position_id.to_s}
                instance2 = type_instance "OtherPosition",
                  {id: employee2.other_position_id.to_s}
                expect {
                  execute(instance1, instance2)
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
              let(:lookahead_selections) { ["first_name", "salary", "age"] }

              it "works as normal" do
                resource.federated_type("OtherPosition").has_many :employees
                schema!([resource])
                instance1 = type_instance "OtherPosition",
                  {id: employee1.other_position_id.to_s}
                instance2 = type_instance "OtherPosition",
                  {id: employee2.other_position_id.to_s}
                batch1, batch2 = execute(instance1, instance2)
                expect(batch1.map { |r| r[:salary] }).to eq([100_000, 100_000])
                expect(batch2.map { |r| r[:salary] }).to eq([100_000, 100_000])
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
            instance1 = type_instance "OtherPosition",
              {id: employee1.other_position_id.to_s}
            instance2 = type_instance "OtherPosition",
              {id: employee2.other_position_id.to_s}
            batch1, batch2 = execute(instance1, instance2)
            expect(batch1.map { |r| r[:last_name] }).to eq(["FOO", "FOO"])
            expect(batch2.map { |r| r[:last_name] }).to eq(["FOO", "FOO"])
          end
        end

        context "when the relationship name is multi-word" do
          before do
            resource.federated_type("OtherPosition")
              .has_many :exemplary_employees
            schema!([resource])
          end

          it "still works" do
            instance1 = type_instance "OtherPosition",
              {id: employee1.other_position_id.to_s}
            instance2 = type_instance "OtherPosition",
              {id: employee2.other_position_id.to_s}

            batch1 = nil
            batch2 = nil
            GraphQL::Batch.batch do
              batch1 = instance1.exemplary_employees(lookahead: lookahead)
              batch2 = instance2.exemplary_employees(lookahead: lookahead)
            end

            expect(batch1.value.map { |r| r[:id] })
              .to eq([employee1.id.to_s, employee4.id.to_s])
            expect(batch2.value.map { |r| r[:id] })
              .to eq([employee2.id.to_s, employee3.id.to_s])
          end
        end

        context "when custom foreign key" do
          it "works" do
            resource.federated_type("OtherPosition").has_many :employees,
              foreign_key: :other_pos_id
            schema!([resource])
            instance1 = type_instance "OtherPosition",
              {id: employee1.other_pos_id.to_s}
            instance2 = type_instance "OtherPosition",
              {id: employee2.other_pos_id.to_s}
            batch1, batch2 = execute(instance1, instance2)
            expect(batch1.map { |r| r[:id] })
              .to eq([employee1.id.to_s, employee3.id.to_s])
            expect(batch2.map { |r| r[:id] })
              .to eq([employee2.id.to_s, employee4.id.to_s])
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
            instance1 = type_instance "OtherPosition",
              {id: employee1.other_pos_id.to_s}
            instance2 = type_instance "OtherPosition",
              {id: employee2.other_pos_id.to_s}
            batch1, batch2 = execute(instance1, instance2)
            expect(batch1.map { |r| r[:id] })
              .to eq([employee1.id.to_s, employee3.id.to_s])
            expect(batch2.map { |r| r[:id] })
              .to eq([employee2.id.to_s, employee4.id.to_s])
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
              instance1 = type_instance "OtherPosition",
                {id: employee1.other_pos_id.to_s}
              instance2 = type_instance "OtherPosition",
                {id: employee2.other_pos_id.to_s}
              batch1, batch2 = execute(instance1, instance2)
              expect(batch1.map { |r| r[:id] })
                .to eq([employee1.id.to_s, employee3.id.to_s])
              expect(batch2.map { |r| r[:id] })
                .to eq([employee2.id.to_s, employee4.id.to_s])
            end
          end
        end

        context "when filtering" do
          it "works" do
            resource.federated_type("OtherPosition").has_many :employees
            schema!([resource])
            instance1 = type_instance "OtherPosition",
              {id: employee1.other_position_id.to_s}
            instance2 = type_instance "OtherPosition",
              {id: employee2.other_position_id.to_s}
            batch1, batch2 = execute(instance1, instance2, {
              filter: {
                firstName: {eq: [employee1.first_name, employee3.first_name]}
              }
            })
            expect(batch1.map { |r| r[:id] }).to eq([employee1.id.to_s])
            expect(batch2.map { |r| r[:id] }).to eq([employee3.id.to_s])
          end
        end

        context "when sorting" do
          it "works" do
            resource.federated_type("OtherPosition").has_many :employees
            schema!([resource])
            instance1 = type_instance "OtherPosition",
              {id: employee1.other_position_id.to_s}
            instance2 = type_instance "OtherPosition",
              {id: employee2.other_position_id.to_s}
            batch1, batch2 = execute(instance1, instance2, {
              sort: [{att: "firstName", dir: "desc"}]
            })
            expect(batch1.map { |r| r[:id] })
              .to eq([employee4.id.to_s, employee1.id.to_s])
            expect(batch2.map { |r| r[:id] })
              .to eq([employee3.id.to_s, employee2.id.to_s])
          end
        end

        context "when paginating" do
          context "when from a single parent node" do
            it "works" do
              resource.federated_type("OtherPosition").has_many :employees
              schema!([resource])
              instance = type_instance "OtherPosition",
                {id: employee1.other_position_id.to_s}
              batch = GraphQL::Batch.batch {
                instance.employees({
                  page: {size: 1, number: 2},
                  lookahead: lookahead
                })
              }
              expect(batch.map { |r| r[:id] }).to eq([employee4.id.to_s])
            end
          end

          context "when from multiple parent nodes" do
            it "works" do
              resource.federated_type("OtherPosition").has_many :employees
              schema!([resource])
              instance1 = type_instance "OtherPosition",
                {id: employee1.other_position_id.to_s}
              instance2 = type_instance "OtherPosition",
                {id: employee2.other_position_id.to_s}
              expect {
                execute(instance1, instance2, {
                  page: {size: 1}
                })
              }.to raise_error(Graphiti::Errors::UnsupportedPagination)
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
        instance = type_instance "Employee",
          {id: visa.employee_id.to_s}
        batch = GraphQL::Batch.batch {
          instance.credit_cards(lookahead: lookahead)
        }
        # NB ensure type and __typename are returned correctly
        expect(batch).to eq([
          {
            id: "1",
            _type: "visas",
            __typename: "POROFederatedVisa",
            employee_id: 1
          },
          {
            id: "2",
            _type: "gold_visas",
            __typename: "POROFederatedGoldVisa",
            employee_id: 1
          },
          {
            id: "3",
            _type: "mastercards",
            __typename: "POROFederatedMastercard",
            employee_id: 1
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
            otherEmp {
              __typename
              id
            }
          }
        }
      ))
      expect(json).to eq({
        positions: [{
          otherEmp: {
            __typename: "OtherEmp",
            id: position.other_emp_id.to_s
          }
        }]
      })
    end

    it "cannot query the reference attribute when not in gql context" do
      position_resource.federated_belongs_to :other_emp
      schema!([position_resource])
      allow(Graphiti).to receive(:context) { {graphql: false} }
      json = run(%(
        query {
          positions {
            otherEmp {
              __typename
              id
            }
          }
        }
      ))
      expect(json).to eq({positions: [{}]})
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

    context "with custom foreign key" do
      it "is correctly referenced" do
        allow_any_instance_of(PORO::Position).to receive(:my_fk) { 9876 }
        position_resource.federated_belongs_to :other_emp,
          foreign_key: :my_fk
        schema!([position_resource])
        json = run(%(
          query {
            positions {
              otherEmp {
                __typename
                id
              }
            }
          }
        ))
        expect(json).to eq({
          positions: [{
            otherEmp: {
              __typename: "OtherEmp",
              id: "9876"
            }
          }]
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
                otherEmp {
                  __typename
                  id
                }
              }
            }
          ))
          expect(json).to eq({
            positions: [{
              otherEmp: {
                __typename: "OtherEmp",
                id: "10000"
              }
            }]
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
                  otherEmp {
                    __typename
                    id
                  }
                }
              }
            ))
            expect(json).to eq({
              positions: [{
                otherEmp: {
                  __typename: "OtherEmp",
                  id: "10000"
                }
              }]
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
              otherEmp {
                __typename
                id
              }
            }
          }
        ))
        expect(json).to eq({
          positions: [{
            otherEmp: {
              __typename: "OtherType",
              id: position.other_emp_id.to_s
            }
          }]
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
              otherEmp {
                __typename
                id
              }
            }
          }
        ))
        expect(json).to eq({
          positions: [{
            otherEmp: {__typename: "OtherEmp", id: position.other_emp_id.to_s}
          }]
        })
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
