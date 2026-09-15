# frozen_string_literal: true

module Kochab
  class Schema
    # Definition context for Schema.define.
    class Builder
      def initialize(path = [])
        @path = path
        @rules = []
      end

      attr_reader :rules

      def boolean(name, **options) = scalar(name, :boolean, **options)
      def integer(name, **options) = scalar(name, :integer, **options)
      def number(name, **options) = scalar(name, :number, **options)
      def string(name, **options) = scalar(name, :string, **options)

      def enum(name, values:, **options)
        raise ArgumentError, "values must be a nonempty Array" unless values.is_a?(Array) && !values.empty?

        types = values.map { |value| Schema.type_of(value) }.uniq
        scalar(name, types.one? ? types.first : :any, enum: values, **options)
      end

      def object(name, **options, &block)
        nested = self.class.new(field_path(name))
        evaluate(nested, block)
        add(name, :object, items: nested.rules.map(&:field).freeze, children: nested.rules, **options)
      end

      def array(name, items:, **options)
        item = Schema.rule_for_type(items, field_path(name) + [0])
        add(name, :array, items: Schema.public_item(item), item: item, **options)
      end

      def map(name, value:, **options)
        path = field_path(name) + ["*"]
        item = if value.respond_to?(:call)
          nested = self.class.new(path)
          value.call(nested)
          Schema.rule(nil, :object, children: nested.rules)
        else
          Schema.rule_for_type(value, path)
        end
        public_items = item.field || item.children.map(&:field).freeze
        add(name, :map, items: public_items, item: item, **options)
      end

      private

      def scalar(name, type, **options)
        add(name, type, **options)
      end

      def add(name, type, default: UNSET, description: nil, enum: nil, minimum: nil,
        maximum: nil, items: nil, deprecated: false, children: [], item: nil)
        path = field_path(name)
        raise ArgumentError, "Duplicate field #{path.join(".")}" if @rules.any? { |rule| rule.field.path == path }

        field = Field.new(path: path.freeze, type: type, default: default.equal?(UNSET) ? nil : Schema.frozen_copy(default),
          description: description, enum: enum && Schema.frozen_copy(enum), minimum: minimum, maximum: maximum,
          items: items, deprecated: deprecated).freeze
        @rules << Schema.rule(field, type, children: children, item: item,
          constraints: {minimum: minimum, maximum: maximum, enum: enum}, default_set: !default.equal?(UNSET))
      end

      def field_path(name)
        raise TypeError, "field names must be nonempty Strings" unless name.is_a?(String) && !name.empty?

        @path + [name]
      end

      def evaluate(builder, block)
        raise ArgumentError, "a schema block is required" unless block

        block.arity.zero? ? builder.instance_eval(&block) : block.call(builder)
      end
    end
  end
end
