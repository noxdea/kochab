# frozen_string_literal: true

module Kochab
  # Typed settings metadata, source-aware validation, and safe layer merging.
  class Schema
    UNSET = Object.new.freeze
    TYPES = %i[any array boolean integer map null number object string].freeze
    Rule = Struct.new(:field, :children, :item, :additional, :required, :constraints,
      :default_set, :default, keyword_init: true)
    private_constant :UNSET, :TYPES, :Rule

    def self.define(&block)
      raise ArgumentError, "a schema block is required" unless block

      builder = Builder.new
      block.arity.zero? ? builder.instance_eval(&block) : block.call(builder)
      new(rule(nil, :object, children: builder.rules))
    end

    def self.from_json_schema(hash)
      raise TypeError, "JSON Schema must be a Hash" unless hash.is_a?(Hash)

      compiler = JsonCompiler.new(hash)
      root = compiler.compile_root
      new(root)
    end

    def initialize(root)
      @root = root
      validate_defaults!
      @fields = collect_fields(root).freeze
    end

    def defaults
      copy(default_for(@root) || {})
    end

    def describe(path)
      rule = find_rule(path)
      rule&.field
    end

    def fields
      @fields.dup
    end

    class << self
      def rule(field, type, children: [], item: nil, additional: true, required: [], constraints: {}, default_set: false)
        Rule.new(field: field, children: children.freeze, item: item, additional: additional,
          required: required.freeze, constraints: constraints.freeze, default_set: default_set,
          default: default_set ? field&.default : nil)
      end

      def rule_for_type(type, path)
        type = normalize_type(type)
        field = Field.new(path: frozen_copy(path), type: type, default: nil, items: nil, deprecated: false).freeze
        rule(field, type)
      end

      def normalize_type(type)
        unless type.is_a?(Array) || type.respond_to?(:to_sym)
          raise ArgumentError, "Unsupported schema type #{type.inspect}"
        end

        normalized = type.is_a?(Array) ? type.map { |entry| normalize_type(entry) }.freeze : type.to_sym
        raise ArgumentError, "Unsupported schema type #{type.inspect}" if normalized.is_a?(Array) && normalized.empty?

        valid = normalized.is_a?(Array) ? normalized.all? { |entry| TYPES.include?(entry) } : TYPES.include?(normalized)
        raise ArgumentError, "Unsupported schema type #{type.inspect}" unless valid

        normalized
      end

      def type_of(value)
        case value
        when nil then :null
        when true, false then :boolean
        when Integer then :integer
        when Numeric then :number
        when String then :string
        when Array then :array
        when Hash then :object
        else :any
        end
      end

      def public_item(rule)
        rule.field&.type
      end

      def copy(value)
        case value
        when Hash then value.to_h { |key, entry| [copy(key), copy(entry)] }
        when Array then value.map { |entry| copy(entry) }
        else value.dup
        end
      rescue TypeError
        value
      end

      def frozen_copy(value)
        freeze_value(copy(value))
      end

      def freeze_value(value)
        case value
        when Hash then value.each { |key, entry| freeze_value(key); freeze_value(entry) }
        when Array then value.each { |entry| freeze_value(entry) }
        end
        value.freeze
      end
    end

    private

    def validate_defaults!
      diagnostics = []
      defaults = default_for(@root) || {}
      validate_rule(@root, defaults, [], nil, diagnostics, check_required: false)
      return if diagnostics.empty?

      raise ArgumentError, "Invalid schema default at #{diagnostics.first.path.join(".")}: #{diagnostics.first.message}"
    end

    def collect_fields(rule, seen = {})
      return [] if seen[rule.object_id]

      seen[rule.object_id] = true
      own = rule.field ? [rule.field] : []
      own + rule.children.flat_map { |child| collect_fields(child, seen) } +
        (rule.item.is_a?(Rule) ? collect_fields(rule.item, seen) : []) +
        (rule.additional.is_a?(Rule) ? collect_fields(rule.additional, seen) : [])
    end

    def default_for(rule, ancestors = {})
      return copy(rule.default) if rule.default_set

      return unless [:object, :map].include?(rule.field&.type || :object)
      return if ancestors[rule.object_id]

      ancestors[rule.object_id] = true
      values = rule.children.each_with_object({}) do |child, result|
        value = default_for(child, ancestors)
        result[child.field.path.last] = value unless value.nil? && !child.default_set
      end
      ancestors.delete(rule.object_id)
      values.empty? ? nil : values
    end

    def find_rule(path)
      raise TypeError, "path must be an Array" unless path.is_a?(Array)

      path.reduce(@root) do |rule, part|
        return nil unless rule
        type = rule.field&.type || :object
        case type
        when :object
          rule.children.find { |child| child.field.path.last == part } || (rule.additional if rule.additional.is_a?(Rule))
        when :map
          return nil unless part.is_a?(String)
          rule.item
        when :array
          return nil unless part.is_a?(Integer) && part >= 0
          rule.item
        end
      end
    end

    def copy(value) = self.class.copy(value)

  end
end

require_relative "schema/builder"
require_relative "schema/json_compiler"
require_relative "schema/validation"
require_relative "schema/merge"
