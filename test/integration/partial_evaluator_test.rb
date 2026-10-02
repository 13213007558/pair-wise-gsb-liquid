# frozen_string_literal: true

require "test_helper"

class PartialEvaluatorTest < Minitest::Test
  class SpyDrop < Liquid::Drop
    class << self
      attr_accessor :calls
    end

    def initialize
      super
      self.class.calls += 1
    end

    def name
      self.class.calls += 1
      "spy"
    end
  end

  class CountingTag < Liquid::Tag
    class << self
      attr_accessor :renders
    end

    def render(_context)
      self.class.renders += 1
      "COUNTED"
    end
  end

  module BoomFilter
    def boom(input)
      raise "boom"
    end
  end

  def setup
    SpyDrop.calls = 0
    CountingTag.renders = 0
  end

  def evaluator(**options)
    Liquid::PartialEvaluator.new(**options)
  end

  def fresh(value)
    Marshal.load(Marshal.dump(value))
  end

  # Renders the original and the residual template with every remaining
  # assign set and asserts identical output.
  def assert_partial_equivalence(source, known, remaining_sets, message: nil, **options)
    result = evaluator(**options).evaluate(source, known)

    remaining_sets.each do |remaining|
      merged = known.merge(remaining)
      expected = Liquid::Template.parse(source).render(fresh(merged))
      # Parse fresh per render: stock Liquid leaks assign/capture into
      # template.instance_assigns when a template object is rendered twice.
      actual = result.template.render(fresh(merged))
      assert_equal(expected, actual, message || "residual output mismatch for #{remaining.inspect}")
    end

    result
  end

  def test_folds_known_variables_with_registered_pure_filters
    result = evaluator(pure_filters: %w[upcase]).evaluate(
      "Hello {{ recipient.name }}, welcome to {{ brand.name | upcase }}!",
      { "brand" => { "name" => "Acme" } },
    )
    assert_equal("Hello {{ recipient.name }}, welcome to ACME!", result.source)
    assert_equal(1, result.preserved.size)
    assert_equal(:unknown_variables, result.preserved.first.reason)
    assert_equal(["recipient"], result.preserved.first.details[:variables])
  end

  def test_unregistered_filters_are_never_executed
    result = evaluator.evaluate("{{ brand.name | upcase }}", { "brand" => { "name" => "Acme" } })
    assert_equal("{{ brand.name | upcase }}", result.source)
    assert_equal(:unregistered_filter, result.preserved.first.reason)
    assert_equal("upcase", result.preserved.first.details[:filter])
  end

  def test_unknown_filters_are_preserved_for_render_time_errors
    source = "{{ brand.name | nosuchfilter }}"
    result = evaluator(pure_filters: %w[nosuchfilter]).evaluate(
      source,
      { "brand" => { "name" => "Acme" } },
    )
    assert_equal(:unknown_filter, result.preserved.first.reason)

    assert_equal(
      Liquid::Template.parse(source).render({ "brand" => { "name" => "Acme" } }),
      result.template.render({ "brand" => { "name" => "Acme" } }),
    )
    assert_raises(Liquid::UndefinedFilter) do
      result.template.render!({ "brand" => { "name" => "Acme" } }, strict_filters: true)
    end
  end

  def test_folds_constants_conditions_and_bounded_loops
    assert_partial_equivalence(
      "{% if brand.vip %}VIP{% endif %}{% for c in brand.colors %}{{ c }};{% endfor %}",
      { "brand" => { "vip" => true, "colors" => %w[red green] } },
      [{}],
    )
    result = evaluator.evaluate(
      "{% if brand.vip %}VIP{% endif %}{% for c in brand.colors %}{{ c }};{% endfor %}",
      { "brand" => { "vip" => true, "colors" => %w[red green] } },
    )
    assert_equal("VIPred;green;", result.source)
    assert(result.fully_evaluated?)
  end

  def test_unknown_branches_are_never_pruned
    result = assert_partial_equivalence(
      "{% if recipient.vip %}A{% elsif brand.staff %}B{% else %}C{% endif %}",
      { "brand" => { "staff" => true } },
      [{ "recipient" => { "vip" => true } }, { "recipient" => { "vip" => false } }],
    )
    assert_includes(result.source, "A")
    assert_includes(result.source, "B")
    assert_includes(result.source, "C")
  end

  def test_unrolls_bounded_loops_with_forloop_metadata
    assert_partial_equivalence(
      "{% for c in brand.colors %}{{ forloop.index }}/{{ forloop.length }}:{{ c }}{% unless forloop.last %},{% endunless %}{% endfor %}",
      { "brand" => { "colors" => %w[a b c] } },
      [{}],
    )
    result = evaluator.evaluate(
      "{% for c in brand.colors %}{{ forloop.index }}:{{ c }};{% endfor %}",
      { "brand" => { "colors" => %w[a b] } },
    )
    assert_equal("1:a;2:b;", result.source)
  end

  def test_dynamic_collection_loop_is_kept_but_body_is_folded
    result = assert_partial_equivalence(
      "{% for o in recipient.orders %}({{ brand.name }}){% endfor %}",
      { "brand" => { "name" => "Acme" } },
      [{ "recipient" => { "orders" => [1, 2] } }, { "recipient" => { "orders" => [] } }],
    )
    assert_equal("{% for o in recipient.orders %}(Acme){% endfor %}", result.source)
    assert_equal(:loop_not_foldable, result.preserved.first.reason)
    assert_equal(:dynamic_collection, result.preserved.first.details[:cause])
  end

  def test_assign_and_capture_fold_into_later_expressions
    assert_partial_equivalence(
      "{% assign x = brand.name %}{{ x }}{% capture g %}Hi {{ recipient.name }}{% endcapture %}{{ g }}",
      { "brand" => { "name" => "Acme" } },
      [{ "recipient" => { "name" => "Bo" } }, { "recipient" => { "name" => "Al" } }],
    )
    result = evaluator.evaluate("{% assign x = brand.name %}{{ x }}", { "brand" => { "name" => "Acme" } })
    assert_equal("Acme", result.source)
  end

  def test_case_unless_and_blank_empty_literals
    assert_partial_equivalence(
      "{% case brand.tier %}{% when 1 %}one{% when 2 %}two{% else %}other{% endcase %}",
      { "brand" => { "tier" => 2 } },
      [{}],
    )
    assert_partial_equivalence(
      "{% unless brand.hidden %}shown{% endunless %}",
      { "brand" => { "hidden" => false } },
      [{}],
    )
    assert_partial_equivalence(
      "{% if brand.note == blank %}blank!{% endif %}{% if brand.list == empty %}empty!{% endif %}",
      { "brand" => { "note" => "", "list" => [] } },
      [{}],
    )
  end

  def test_drop_methods_are_never_called_during_preprocessing
    result = evaluator.evaluate(
      "{{ settings.name }} {{ settings }}",
      { "settings" => SpyDrop.new },
    )
    assert_equal(1, SpyDrop.calls, "only the constructor may run")
    assert_equal(2, result.preserved.size)
    assert_partial_equivalence(
      "{{ settings.name }}",
      { "settings" => SpyDrop.new },
      [{}],
    )
  end

  def test_dynamic_include_is_not_executed
    file_system = Object.new
    def file_system.read_template_file(_name)
      raise "file system must not be read during preprocessing"
    end

    environment = Liquid::Environment.build(file_system: file_system)
    result = Liquid::PartialEvaluator.new(environment: environment).evaluate(
      "{% include template_name %}",
      {},
    )
    assert_equal("{% include template_name %}", result.source)
    assert_equal(:template_include, result.preserved.first.reason)
  end

  def test_custom_tags_are_preserved_not_executed
    environment = Liquid::Environment.build { |env| env.register_tag("counting", CountingTag) }
    result = Liquid::PartialEvaluator.new(environment: environment).evaluate(
      "{% counting %}{{ brand.x }}",
      { "brand" => { "x" => "!" } },
    )
    assert_equal(0, CountingTag.renders)
    assert_equal("{% counting %}!", result.source)
    assert_equal(:custom_tag, result.preserved.first.reason)
    assert_equal("COUNTED!", result.template.render({ "brand" => { "x" => "!" } }))
    assert_equal(1, CountingTag.renders)
  end

  def test_stateful_tags_are_preserved
    assert_partial_equivalence("{% increment c %}{% increment c %}{{ c }}", {}, [{}])
    assert_partial_equivalence("{% cycle \"a\", \"b\" %}{% cycle \"a\", \"b\" %}", {}, [{}])
    assert_partial_equivalence("{% for i in (1..3) %}{{ i }}{% ifchanged %}x{% endifchanged %}{% endfor %}", {}, [{}])
  end

  def test_same_residual_matches_original_for_many_remaining_assign_sets
    source = "{% if brand.vip %}V{% endif %}{{ recipient.name | upcase }}" +      "{% for o in recipient.orders %}[{{ o.id }}:{{ brand.currency }}]{% endfor %}" +      "{% if recipient.gift %}G{% else %}N{% endif %}"
    result = assert_partial_equivalence(
      source,
      { "brand" => { "vip" => true, "currency" => "USD" } },
      [
        { "recipient" => { "name" => "a", "orders" => [{ "id" => 1 }], "gift" => true } },
        { "recipient" => { "name" => "b", "orders" => [], "gift" => false } },
        { "recipient" => { "name" => "c", "orders" => [{ "id" => 1 }, { "id" => 2 }], "gift" => true } },
      ],
      pure_filters: %w[upcase],
    )
    assert_equal(
      "V{{ recipient.name | upcase }}{% for o in recipient.orders %}[{{ o.id }}:USD]{% endfor %}{% if recipient.gift %}G{% else %}N{% endif %}",
      result.source,
    )
  end

  def test_render_time_exceptions_match_the_original
    environment = Liquid::Environment.build { |env| env.register_filters([BoomFilter]) }
    evaluator = Liquid::PartialEvaluator.new(environment: environment, pure_filters: %w[boom])
    result = evaluator.evaluate("{{ brand.x | boom }}", { "brand" => { "x" => 1 } })
    assert_equal(:filter_error, result.preserved.first.reason)

    original_error = assert_raises(RuntimeError) do
      Liquid::Template.parse("{{ brand.x | boom }}", environment: environment).render!({ "brand" => { "x" => 1 } })
    end
    residual_error = assert_raises(RuntimeError) do
      result.template.render!({ "brand" => { "x" => 1 } })
    end
    assert_equal(original_error.message, residual_error.message)
  end

  def test_strict_variables_missing_lookups_are_preserved
    result = evaluator(strict_variables: true).evaluate("{{ brand.missing }}", { "brand" => {} })
    assert_equal("{{ brand.missing }}", result.source)
    assert_raises(Liquid::UndefinedVariable) do
      result.template.render!({ "brand" => {} }, strict_variables: true)
    end
  end

  def test_syntax_errors_are_raised_like_template_parse
    assert_raises(Liquid::SyntaxError) { evaluator.evaluate("{% if x %}", {}) }
    assert_raises(Liquid::SyntaxError) { evaluator.evaluate("{% unknown_tag_xyz %}", {}) }
  end

  def test_preserved_report_exposes_markup_line_and_reason
    source = "line1\n{{ brand.name | upcase }}\n{% include \"x\" %}"
    result = evaluator.evaluate(source, { "brand" => { "name" => "Acme" } })
    variable, include_tag = result.preserved
    assert_equal(:variable, variable.kind)
    assert_equal("brand.name | upcase", variable.markup)
    assert_equal(2, variable.line_number)
    assert_equal(:unregistered_filter, variable.reason)
    assert_equal(:tag, include_tag.kind)
    assert_equal(:template_include, include_tag.reason)
    assert_equal(3, include_tag.line_number)
  end

  def test_folded_output_cannot_be_reparsed_as_template_syntax
    assert_partial_equivalence(
      "{{ brand.txt }}",
      { "brand" => { "txt" => "a {{ recipient }} b" } },
      [{ "recipient" => "X" }],
    )
    result = evaluator.evaluate("{{ brand.txt }}", { "brand" => { "txt" => "a {{ recipient }} b" } })
    assert_equal("{% raw %}a {{ recipient }} b{% endraw %}", result.source)
    assert_equal("a {{ recipient }} b", result.template.render)
  end

  def test_whitespace_control_is_preserved_when_tags_are_removed
    assert_partial_equivalence("A {%- assign x = 1 -%} B", {}, [{}])
    assert_partial_equivalence("A {%- if brand.ok -%} B {%- endif -%} C", { "brand" => { "ok" => true } }, [{}])
    assert_partial_equivalence("{{ recipient.a -}}{{ brand.x }}", { "brand" => { "x" => " 5" } }, [{ "recipient" => { "a" => "A" } }])
    assert_partial_equivalence("{{ brand.x }}{%- if recipient.ok %}Y{% endif %}", { "brand" => { "x" => "5 " } }, [{ "recipient" => { "ok" => true } }])
    assert_partial_equivalence("{% if brand.ok %} {% endif %}{%- if recipient.ok %}b{% endif %}", { "brand" => { "ok" => true } }, [{ "recipient" => { "ok" => true } }])
  end

  def test_loop_variable_escape_prevents_unrolling
    assert_partial_equivalence(
      "{% for i in (1..3) %}{{ i | append: recipient.x }}{% endfor %}",
      {},
      [{ "recipient" => { "x" => "!" } }],
      pure_filters: %w[append],
    )
    result = evaluator(pure_filters: %w[append]).evaluate(
      "{% for i in (1..3) %}{{ i | append: recipient.x }}{% endfor %}",
      {},
    )
    assert_equal("{% for i in (1..3) %}{{ i | append: recipient.x }}{% endfor %}", result.source)
  end

  def test_break_continue_and_too_large_loops_are_not_unrolled
    assert_partial_equivalence("{% for i in (1..3) %}{% break %}{{ i }}{% endfor %}", {}, [{}])
    assert_partial_equivalence("{% for i in (1..200) %}{{ i }}{% endfor %}", {}, [{}])
    result = evaluator.evaluate("{% for i in (1..200) %}{{ i }}{% endfor %}", {})
    assert_equal(:loop_not_foldable, result.preserved.first.reason)
    assert_equal(:too_large, result.preserved.first.details[:cause])
  end

  def test_assignments_inside_dynamic_regions_stay_in_residual
    assert_partial_equivalence(
      "{% assign x = 1 %}{% if recipient.ok %}{% assign x = 2 %}{% endif %}{{ x }}",
      {},
      [{ "recipient" => { "ok" => true } }, { "recipient" => { "ok" => false } }],
    )
    assert_partial_equivalence(
      "{% assign c = 5 %}{% increment c %}{{ c }}",
      {},
      [{}],
    )
  end

  def test_result_template_renders_with_only_remaining_assigns_when_fully_folded
    result = evaluator(pure_filters: %w[upcase]).evaluate(
      "{% if brand.vip %}{{ brand.name | upcase }}{% endif %}",
      { "brand" => { "vip" => true, "name" => "Acme" } },
    )
    assert(result.fully_evaluated?)
    assert_equal("ACME", result.template.render)
  end
end
