# frozen_string_literal: true

require "active_support/core_ext/numeric/time"
require "active_support/core_ext/object/json"

RSpec.describe Busybee::Serialization do
  describe ".to_json" do
    it "serializes a simple hash to JSON" do
      result = described_class.to_json({ name: "test", count: 42 })
      expect(result).to eq('{"name":"test","count":42}')
    end

    it "serializes nested hashes" do
      result = described_class.to_json({ order: { id: "123", amount: 99.99 } })
      parsed = JSON.parse(result)
      expect(parsed).to eq({ "order" => { "id" => "123", "amount" => 99.99 } })
    end

    it "serializes arrays" do
      result = described_class.to_json({ items: [1, 2, 3] })
      expect(JSON.parse(result)).to eq({ "items" => [1, 2, 3] })
    end

    it "calls as_json on the input before serializing" do
      # Object with custom as_json
      obj = Object.new
      def obj.as_json(*)
        { "custom" => "serialization" }
      end

      result = described_class.to_json(obj)
      expect(JSON.parse(result)).to eq({ "custom" => "serialization" })
    end

    it "serializes Time objects to ISO8601 via as_json" do
      time = Time.utc(2024, 1, 15, 10, 30, 0)
      result = described_class.to_json({ created_at: time })
      parsed = JSON.parse(result)

      expect(parsed["created_at"]).to eq("2024-01-15T10:30:00.000Z")
    end

    it "serializes ActiveSupport::Duration to numeric seconds via as_json" do
      # Duration.as_json returns the numeric value in seconds, not ISO8601
      result = described_class.to_json({ timeout: 5.seconds })
      parsed = JSON.parse(result)
      expect(parsed["timeout"]).to eq(5)

      result2 = described_class.to_json({ timeout: 1.hour + 30.minutes })
      parsed2 = JSON.parse(result2)
      expect(parsed2["timeout"]).to eq(5400)
    end

    it "handles empty hash" do
      result = described_class.to_json({})
      expect(result).to eq("{}")
    end

    it "handles hash with symbol keys" do
      result = described_class.to_json({ foo: "bar" })
      expect(JSON.parse(result)).to eq({ "foo" => "bar" })
    end

    it "handles hash with string keys" do
      result = described_class.to_json({ "foo" => "bar" })
      expect(JSON.parse(result)).to eq({ "foo" => "bar" })
    end
  end

  describe ".from_json" do
    it "parses JSON string into a hash" do
      result = described_class.from_json('{"name":"test","count":42}')
      expect(result).to eq({ "name" => "test", "count" => 42 })
    end

    it "returns HashWithIndifferentAccess" do
      result = described_class.from_json('{"name":"test"}')
      expect(result).to be_a(ActiveSupport::HashWithIndifferentAccess)
      expect(result[:name]).to eq("test")
      expect(result["name"]).to eq("test")
    end

    it "returns empty frozen hash for nil input" do
      result = described_class.from_json(nil)
      expect(result).to eq({})
      expect(result).to be_a(ActiveSupport::HashWithIndifferentAccess)
      expect(result).to be_frozen
    end

    it "returns empty frozen hash for empty string input" do
      result = described_class.from_json("")
      expect(result).to eq({})
      expect(result).to be_a(ActiveSupport::HashWithIndifferentAccess)
      expect(result).to be_frozen
    end

    it "parses nested hashes with indifferent access" do
      json = '{"order":{"id":"123","amount":99.99}}'
      result = described_class.from_json(json)

      expect(result[:order][:id]).to eq("123")
      expect(result["order"]["amount"]).to eq(99.99)
      expect(result[:order]["id"]).to eq("123")
    end

    it "parses arrays" do
      json = '{"items":[1,2,3]}'
      result = described_class.from_json(json)
      expect(result[:items]).to eq([1, 2, 3])
    end

    it "parses arrays of hashes with indifferent access" do
      json = '{"orders":[{"id":"1"},{"id":"2"}]}'
      result = described_class.from_json(json)

      expect(result[:orders].first[:id]).to eq("1")
      expect(result[:orders].last["id"]).to eq("2")
    end

    it "raises Busybee::InvalidJobJson for invalid JSON" do
      expect { described_class.from_json("{invalid json") }.to raise_error(Busybee::InvalidJobJson)
    end

    it "wraps the original JSON::ParserError as cause" do
      described_class.from_json("{invalid json")
    rescue Busybee::InvalidJobJson => e
      expect(e.cause).to be_a(JSON::ParserError)
    end

    it "includes the parser error message" do
      expect { described_class.from_json("{invalid") }.to raise_error(
        Busybee::InvalidJobJson,
        /Failed to parse JSON:.*expected|Failed to parse JSON:.*unexpected/i
      )
    end

    describe "frozen by default" do
      it "returns a frozen hash" do
        result = described_class.from_json('{"name":"test"}')
        expect(result).to be_frozen
      end

      it "prevents modification of returned hash" do
        result = described_class.from_json('{"name":"test"}')
        expect { result[:new_key] = "value" }.to raise_error(FrozenError)
      end

      it "freezes nested hashes" do
        result = described_class.from_json('{"order":{"id":"123"}}')
        expect(result[:order]).to be_frozen
      end

      it "freezes deeply nested hashes" do
        result = described_class.from_json('{"a":{"b":{"c":"deep"}}}')
        expect(result[:a][:b]).to be_frozen
      end

      it "freezes arrays" do
        result = described_class.from_json('{"items":[1,2,3]}')
        expect(result[:items]).to be_frozen
      end

      it "freezes hashes within arrays" do
        result = described_class.from_json('{"orders":[{"id":"1"}]}')
        expect(result[:orders].first).to be_frozen
      end
    end

    describe "method-style access (HashAccess)" do
      it "supports method-style access on top-level keys" do
        result = described_class.from_json('{"order_id":"123"}')
        expect(result.order_id).to eq("123")
      end

      it "supports method-style access with snake_case to camelCase conversion" do
        result = described_class.from_json('{"processTimeout":"PT1H"}')
        expect(result.process_timeout).to eq("PT1H")
      end

      it "chains method-style access to nested hashes" do
        json = '{"order":{"customerId":"abc","totalAmount":99.99}}'
        result = described_class.from_json(json)

        expect(result.order).to be_a(ActiveSupport::HashWithIndifferentAccess)
        expect(result.order.customer_id).to eq("abc")
        expect(result.order.total_amount).to eq(99.99)
      end

      it "supports deeply nested method access" do
        json = '{"order":{"customer":{"firstName":"Jane","lastName":"Doe"}}}'
        result = described_class.from_json(json)

        expect(result.order.customer.first_name).to eq("Jane")
        expect(result.order.customer.last_name).to eq("Doe")
      end

      it "raises NoMethodError for non-existent keys" do
        result = described_class.from_json('{"name":"test"}')
        expect { result.non_existent_key }.to raise_error(NoMethodError)
      end

      it "responds_to? returns true for existing keys" do
        result = described_class.from_json('{"orderId":"123"}')
        expect(result).to respond_to(:order_id)
        expect(result).not_to respond_to(:non_existent)
      end

      it "works with arrays of hashes" do
        json = '{"items":[{"productName":"Widget"},{"productName":"Gadget"}]}'
        result = described_class.from_json(json)

        expect(result.items.first.product_name).to eq("Widget")
        expect(result.items.last.product_name).to eq("Gadget")
      end
    end
  end

  describe "HashAccess module" do
    it "is defined on the Serialization module" do
      expect(defined?(Busybee::Serialization::HashAccess)).to eq("constant")
    end
  end
end
