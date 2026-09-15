# frozen_string_literal: true

module Kochab
  class Schema
    def validate(document)
      raise TypeError, "document must be a Kochab::Document" unless document.is_a?(Document)

      diagnostics = []
      validate_rule(@root, document.value, [], document, diagnostics)
      diagnostics
    end

    private

    def validate_rule(rule, value, path, document, diagnostics, check_required: true)
      type = rule.field&.type || :object
      unless type_match?(type, value)
        return add_diagnostic(diagnostics, document, path, "Expected #{Array(type).join(" or ")}")
      end

      constraints = rule.constraints
      add_diagnostic(diagnostics, document, path, "Must be one of #{constraints[:enum].inspect}") if constraints[:enum] && !constraints[:enum].include?(value)
      add_diagnostic(diagnostics, document, path, "Must be at least #{constraints[:minimum]}") if constraints[:minimum] && value.is_a?(Numeric) && value < constraints[:minimum]
      add_diagnostic(diagnostics, document, path, "Must be at most #{constraints[:maximum]}") if constraints[:maximum] && value.is_a?(Numeric) && value > constraints[:maximum]
      add_diagnostic(diagnostics, document, path, "Must be greater than #{constraints[:exclusive_minimum]}") if constraints[:exclusive_minimum] && value.is_a?(Numeric) && value <= constraints[:exclusive_minimum]
      add_diagnostic(diagnostics, document, path, "Must be less than #{constraints[:exclusive_maximum]}") if constraints[:exclusive_maximum] && value.is_a?(Numeric) && value >= constraints[:exclusive_maximum]
      add_size_diagnostics(diagnostics, document, path, value, constraints)
      validate_container(rule, value, path, document, diagnostics, check_required: check_required)
    end

    def validate_container(rule, value, path, document, diagnostics, check_required: true)
      type = matching_type(rule.field&.type || :object, value)
      if type == :array
        value.each_with_index { |entry, index| validate_rule(rule.item, entry, path + [index], document, diagnostics, check_required: check_required) } if rule.item
      elsif type == :map
        value.each do |key, entry|
          if key.is_a?(String)
            validate_rule(rule.item, entry, path + [key], document, diagnostics, check_required: check_required) if rule.item
          else
            add_diagnostic(diagnostics, document, path + [key], "Map keys must be Strings")
          end
        end
      elsif type == :object
        validate_object(rule, value, path, document, diagnostics, check_required: check_required)
      end
    end

    def add_size_diagnostics(diagnostics, document, path, value, constraints)
      return unless value.respond_to?(:length)

      minimum = value.is_a?(String) ? constraints[:min_length] : constraints[value.is_a?(Array) ? :min_items : :min_properties]
      maximum = value.is_a?(String) ? constraints[:max_length] : constraints[value.is_a?(Array) ? :max_items : :max_properties]
      add_diagnostic(diagnostics, document, path, "Must contain at least #{minimum} entries") if minimum && value.length < minimum
      add_diagnostic(diagnostics, document, path, "Must contain at most #{maximum} entries") if maximum && value.length > maximum
    end

    def validate_object(rule, value, path, document, diagnostics, check_required: true)
      rule.required.each do |name|
        add_diagnostic(diagnostics, document, path + [name], "Required value is missing", path) unless value.key?(name)
      end if check_required
      value.each do |name, entry|
        child = rule.children.find { |candidate| candidate.field.path.last == name }
        child ||= rule.additional if rule.additional.is_a?(Rule)
        add_diagnostic(diagnostics, document, path + [name], "Unknown field") if !child && !rule.additional
        validate_rule(child, entry, path + [name], document, diagnostics, check_required: check_required) if child
      end
    end

    def add_diagnostic(diagnostics, document, path, message, range_path = path)
      range = document && (document.range_of(range_path) || document.range_of(range_path[0...-1]))
      diagnostics << Diagnostic.new(path: path.freeze, range: range, severity: :error, message: message)
    end

    def type_match?(type, value)
      return type.any? { |entry| type_match?(entry, value) } if type.is_a?(Array)

      case type
      when :any then true
      when :null then value.nil?
      when :boolean then value.equal?(true) || value.equal?(false)
      when :integer then value.is_a?(Integer)
      when :number then value.is_a?(Numeric) && (!value.respond_to?(:finite?) || value.finite?)
      when :string then value.is_a?(String)
      when :array then value.is_a?(Array)
      when :object, :map then value.is_a?(Hash)
      else false
      end
    end

    def matching_type(type, value)
      type.is_a?(Array) ? type.find { |entry| type_match?(entry, value) } : type
    end
  end
end
