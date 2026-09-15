# frozen_string_literal: true

module Kochab
  class Schema
    def merge(*documents)
      documents.reduce(defaults) do |values, document|
        if document.is_a?(Document)
          layer = document.value
          next values unless layer.is_a?(Hash)
        else
          layer = document
          raise TypeError, "layers must be Kochab::Document or Hash values" unless layer.is_a?(Hash)
        end

        merge_object(values, layer, @root)
      end
    end

    private

    def merge_object(previous, layer, rule)
      merge_members(previous, layer, rule).first
    end

    def merge_members(previous, layer, rule)
      result = copy(previous)
      changed = layer.empty?
      layer.each do |name, value|
        child = rule.children.find { |candidate| candidate.field.path.last == name }
        child ||= rule.additional if rule.additional.is_a?(Rule)
        if child
          merged, valid = merge_value(result.fetch(name, UNSET), value, child)
          result[name] = merged if valid
          changed ||= valid
        elsif rule.additional
          result[name] = merge_untyped(result.fetch(name, UNSET), value)
          changed = true
        end
      end
      [result, changed]
    end

    def merge_value(previous, value, rule)
      return [previous, false] unless type_match?(rule.field&.type || :object, value)
      type = matching_type(rule.field&.type || :object, value)
      if type == :object
        base = previous.is_a?(Hash) ? previous : {}
        candidate, changed = merge_members(base, value, rule)
        return [candidate, changed && valid_value?(rule, candidate)] if previous.equal?(UNSET)

        return [candidate, valid_value?(rule, candidate)]
      end
      if type == :map
        result = previous.is_a?(Hash) ? copy(previous) : {}
        changed = value.empty?
        value.each do |name, entry|
          next unless name.is_a?(String)

          merged, valid = merge_value(result.fetch(name, UNSET), entry, rule.item)
          result[name] = merged if valid
          changed ||= valid
        end
        return [result, changed && valid_value?(rule, result)] if previous.equal?(UNSET)

        return [result, valid_value?(rule, result)]
      end

      [copy(value), valid_value?(rule, value)]
    end

    def valid_value?(rule, value)
      diagnostics = []
      validate_rule(rule, value, [], nil, diagnostics)
      diagnostics.empty?
    end

    def merge_untyped(previous, value)
      return copy(value) unless previous.is_a?(Hash) && value.is_a?(Hash)

      value.each_with_object(copy(previous)) do |(name, entry), result|
        result[name] = merge_untyped(result.fetch(name, UNSET), entry)
      end
    end
  end
end
