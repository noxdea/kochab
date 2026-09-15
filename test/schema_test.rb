# frozen_string_literal: true

require_relative "test_helper"

class SchemaTest < Minitest::Test
  def setup
    @schema = Kochab::Schema.define do
      boolean "format_on_save", default: false, description: "Format on save"
      integer "font_size", default: 14, minimum: 6, maximum: 96
      enum "theme", values: %w[auto light dark], default: "auto"
      object "minimap" do
        boolean "enabled", default: false
        integer "width", default: 100, minimum: 20, maximum: 400
      end
      array "code_actions_on_save", items: :string, default: []
      map "languages", value: ->(schema) { schema.integer "tab_size", default: 2, minimum: 1 }
    end
  end

  def test_dsl_builds_defaults_and_metadata
    assert_equal({
      "format_on_save" => false,
      "font_size" => 14,
      "theme" => "auto",
      "minimap" => {"enabled" => false, "width" => 100},
      "code_actions_on_save" => []
    }, @schema.defaults)

    @schema.defaults["minimap"]["width"] = 1
    assert_equal 100, @schema.defaults.dig("minimap", "width")
    assert_equal :integer, @schema.describe(["minimap", "width"]).type
    assert_equal :integer, @schema.describe(["languages", "ruby", "tab_size"]).type
    assert_equal %w[auto light dark], @schema.describe(["theme"]).enum
    assert_includes @schema.fields.map(&:path), ["languages", "*", "tab_size"]
    assert_nil @schema.describe(["missing"])
  end

  def test_validate_reports_value_ranges_for_each_constraint
    text = <<~JSONC
      {
        "format_on_save": "yes",
        "font_size": 4,
        "theme": "blue",
        "minimap": {"width": 500},
        "code_actions_on_save": ["fix", 1],
        "languages": {"ruby": {"tab_size": 0}}
      }
    JSONC
    document = Kochab.parse(text)
    diagnostics = @schema.validate(document)

    expected_paths = [["format_on_save"], ["font_size"], ["theme"], ["minimap", "width"],
      ["code_actions_on_save", 1], ["languages", "ruby", "tab_size"]]
    assert_equal expected_paths, diagnostics.map(&:path)
    diagnostics.each do |diagnostic|
      assert_equal document.range_of(diagnostic.path), diagnostic.range
      assert_equal :error, diagnostic.severity
    end
    assert_equal '"yes"', text.byteslice(diagnostics.first.range)
  end

  def test_merge_is_deep_later_wins_and_skips_only_invalid_values
    first = Kochab.parse(<<~JSONC)
      {
        "font_size": 16,
        "minimap": {"enabled": true, "width": 120},
        "code_actions_on_save": ["first"],
        "languages": {"ruby": {"tab_size": 4}, "go": {"tab_size": 8}, "rust": {}},
        "extension": {"old": true}
      }
    JSONC
    second = Kochab.parse(<<~JSONC)
      {
        "font_size": "large",
        "minimap": {"enabled": false, "width": 999},
        "code_actions_on_save": ["second"],
        "languages": {"ruby": {"tab_size": 0}, "go": {"tab_size": 2}, "zig": {"tab_size": 0}},
        "extension": {"new": true}
      }
    JSONC

    result = @schema.merge(first, second)
    assert_equal 16, result["font_size"]
    assert_equal({"enabled" => false, "width" => 120}, result["minimap"])
    assert_equal ["second"], result["code_actions_on_save"]
    assert_equal 4, result.dig("languages", "ruby", "tab_size")
    assert_equal 2, result.dig("languages", "go", "tab_size")
    assert_equal 2, result.dig("languages", "rust", "tab_size")
    assert_equal 2, result.dig("languages", "zig", "tab_size")
    assert_equal({"old" => true, "new" => true}, result["extension"])
  end

  def test_json_schema_subset_supports_nested_values_arrays_and_local_refs
    schema = Kochab::Schema.from_json_schema({
      "type" => "object",
      "required" => ["mode"],
      "properties" => {
        "mode" => {"$ref" => "#/$defs/mode"},
        "names" => {"type" => "array", "items" => {"type" => "string"}, "maxItems" => 2},
        "panel" => {"type" => "object", "additionalProperties" => false,
          "properties" => {"size" => {"type" => "number", "exclusiveMinimum" => 0}}}
      },
      "$defs" => {"mode" => {"type" => "string", "enum" => %w[light dark], "default" => "dark"}}
    })
    document = Kochab.parse('{"mode":"blue","names":["a","b","c"],"panel":{"size":0,"extra":true}}')

    assert_equal({"mode" => "dark"}, schema.defaults)
    assert_equal [["mode"], ["names"], ["panel", "size"], ["panel", "extra"]], schema.validate(document).map(&:path)
    assert_equal "dark", schema.merge(document)["mode"]
    assert_raises(ArgumentError) { Kochab::Schema.from_json_schema({"type" => "string"}) }

    required = Kochab::Schema.from_json_schema({"type" => "object", "required" => ["name"],
      "properties" => {"name" => {"type" => "string"}}})
    assert_empty required.defaults
    assert_equal [["name"]], required.validate(Kochab.parse("{}")).map(&:path)

    root_default = Kochab::Schema.from_json_schema({"type" => "object", "default" => {"name" => "Kochab"},
      "properties" => {"name" => {"type" => "string"}}})
    assert_equal({"name" => "Kochab"}, root_default.defaults)
  end

  def test_schema_definition_rejects_invalid_defaults_and_arguments
    assert_raises(ArgumentError) { Kochab::Schema.define { integer "n", default: "one" } }
    assert_raises(ArgumentError) { Kochab::Schema.define { enum "x", values: [] } }
    assert_raises(ArgumentError) { Kochab::Schema.define { array "x", items: :missing } }
    assert_raises(TypeError) { @schema.validate({}) }
    assert_raises(TypeError) { @schema.merge([]) }
    assert_equal @schema.defaults, @schema.merge(Kochab.parse("[]"))
    assert_raises(TypeError) { @schema.describe("font_size") }
    assert_raises(FrozenError) { @schema.describe(["code_actions_on_save"]).default << "fix" }
    assert_raises(TypeError) { Kochab::Schema.define { integer "n", minimum: "zero" } }
    assert_raises(TypeError) { Kochab::Schema.define { string "x", deprecated: nil } }

    description = +"Stable"
    schema = Kochab::Schema.define { string "x", description: description }
    description.replace("Changed")
    assert_equal "Stable", schema.describe(["x"]).description
    assert schema.describe(["x"]).description.frozen?
  end

  def test_json_schema_references_and_constraints_are_checked_at_compile_time
    target = {"type" => "object", "properties" => {"count" => {"type" => "integer", "default" => 1}}}
    schema = Kochab::Schema.from_json_schema({"$ref" => "#/$defs/root", "$defs" => {"root" => target}})
    assert_equal({"count" => 1}, schema.defaults)

    node = {"type" => "object", "properties" => {}}
    node["properties"]["next"] = {"$ref" => "#/$defs/node"}
    recursive = Kochab::Schema.from_json_schema({"type" => "object", "properties" => {"node" => node}, "$defs" => {"node" => node}})
    assert_empty recursive.validate(Kochab.parse('{"node":{"next":{"next":{}}}}'))

    assert_raises(TypeError) do
      Kochab::Schema.from_json_schema({"type" => "object", "properties" => {"n" => {"type" => "integer", "minimum" => "zero"}}})
    end
    assert_raises(TypeError) { Kochab::Schema.from_json_schema({"type" => "object", "maxProperties" => -1}) }

    looped = {"$ref" => "#/$defs/loop"}
    assert_raises(ArgumentError) { Kochab::Schema.from_json_schema(looped.merge("$defs" => {"loop" => looped})) }
  end
end
