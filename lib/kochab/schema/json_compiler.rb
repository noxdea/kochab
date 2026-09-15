# frozen_string_literal: true

module Kochab
  class Schema
    # Compiles the documented JSON Schema subset into internal rules.
    class JsonCompiler
      def initialize(root)
        @root = root
        @active = {}
      end

      def compile(schema, path)
        raise TypeError, "JSON Schema entries must be Hash values" unless schema.is_a?(Hash)
        return compile(reference(schema.fetch("$ref")), path) if schema.key?("$ref")
        return @active[schema.object_id] if @active.key?(schema.object_id)

        properties = schema.fetch("properties", {})
        required = schema.fetch("required", [])
        raise TypeError, "JSON Schema properties must be a Hash" unless properties.is_a?(Hash)
        raise TypeError, "JSON Schema required must be an Array" unless required.is_a?(Array)
        unless properties.keys.all? { |name| name.is_a?(String) } && required.all? { |name| name.is_a?(String) }
          raise TypeError, "JSON Schema property names must be Strings"
        end
        validate_keywords(schema)

        type = infer_type(schema)
        field = path.empty? ? nil : public_field(schema, path, type)
        rule = Rule.new(field: field, children: [], item: nil, additional: true, required: [], constraints: {},
          default_set: schema.key?("default"),
          default: schema.key?("default") ? Schema.frozen_copy(schema["default"]) : nil)
        @active[schema.object_id] = rule
        rule.children = properties.map { |name, child| compile(child, path + [name]) }.freeze
        rule.item = compile(schema["items"], path + [0]) if schema["items"].is_a?(Hash)
        rule.additional = additional(schema, path)
        rule.required = required.dup.freeze
        rule.constraints = constraints(schema).freeze
        @active.delete(schema.object_id)
        rule
      end

      private

      def infer_type(schema)
        type = schema["type"]
        type ||= "object" if schema.key?("properties") || schema.key?("additionalProperties")
        Schema.normalize_type(type || :any)
      end

      def public_field(schema, path, type)
        items = schema["items"] && Schema.normalize_type(schema["items"]["type"] || :any)
        Field.new(path: Schema.frozen_copy(path), type: type, default: schema.key?("default") ? Schema.frozen_copy(schema["default"]) : nil,
          description: schema["description"], enum: schema["enum"] && Schema.frozen_copy(schema["enum"]),
          minimum: schema["minimum"], maximum: schema["maximum"], items: items,
          deprecated: schema.fetch("deprecated", false)).freeze
      end

      def additional(schema, path)
        value = schema.fetch("additionalProperties", true)
        unless value.equal?(true) || value.equal?(false) || value.is_a?(Hash)
          raise TypeError, "JSON Schema additionalProperties must be true, false, or a Hash"
        end

        value.is_a?(Hash) ? compile(value, path + ["*"]) : value
      end

      def constraints(schema)
        {enum: schema["enum"] && Schema.frozen_copy(schema["enum"]), minimum: schema["minimum"], maximum: schema["maximum"],
         exclusive_minimum: schema["exclusiveMinimum"], exclusive_maximum: schema["exclusiveMaximum"],
         min_items: schema["minItems"], max_items: schema["maxItems"],
         min_length: schema["minLength"], max_length: schema["maxLength"],
         min_properties: schema["minProperties"], max_properties: schema["maxProperties"]}
      end

      def validate_keywords(schema)
        raise TypeError, "JSON Schema items must be a Hash" if schema.key?("items") && !schema["items"].is_a?(Hash)
        unless !schema.key?("enum") || schema["enum"].is_a?(Array) && !schema["enum"].empty?
          raise TypeError, "JSON Schema enum must be a nonempty Array"
        end
        if schema.key?("description") && !schema["description"].is_a?(String)
          raise TypeError, "JSON Schema description must be a String"
        end
        unless [true, false].include?(schema.fetch("deprecated", false))
          raise TypeError, "JSON Schema deprecated must be true or false"
        end
      end

      def reference(pointer)
        raise ArgumentError, "Only local JSON Schema references are supported" unless pointer.is_a?(String) && pointer.start_with?("#")

        pointer.delete_prefix("#").split("/").reject(&:empty?).reduce(@root) do |value, token|
          value.fetch(token.gsub("~1", "/").gsub("~0", "~"))
        end
      rescue KeyError
        raise ArgumentError, "Unknown JSON Schema reference #{pointer.inspect}"
      end
    end
    private_constant :JsonCompiler
  end
end
