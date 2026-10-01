# frozen_string_literal: true

require 'test_helper'

class SpecializerTest < Minitest::Test
  module CountingFilters
    class << self
      def reset!
        counters.each_key { |k| counters[k] = 0 }
      end

      def counters
        @counters ||= Hash.new(0)
      end
    end

    def count_upcase(input)
      CountingFilters.counters[:upcase] += 1
      input.to_s.upcase
    end

    def count_replace(input, pattern, replacement)
      CountingFilters.counters[:replace] += 1
      input.to_s.gsub(pattern, replacement)
    end

    # Always raises: safe to place in branches that must never execute.
    def explode(_input)
      CountingFilters.counters[:explode] += 1
      raise Liquid::ArgumentError, "explode filter must never run"
    end
  end

  module SideEffectFilter
    def side_effect(input)
      SideEffectFilter.counter.call
      input
    end
  end

  def setup
    Liquid::Environment.default.register_filter(CountingFilters)
    @env = Liquid::Environment.default
    CountingFilters.reset!
  end

  def render_pair(source, known, dynamic, pure_filters: [])
    original = Liquid::Template.parse(source)
    expected = original.render!(dynamic.merge(known))
    specialized = Liquid::Template.parse(source).specialize(
      known, pure_filters: pure_filters, filters: [CountingFilters]
    )
    actual = specialized.render!(dynamic, filters: [CountingFilters])
    [expected, actual, specialized]
  end

  def assert_specializes_equally(source, known, dynamic, **options)
    expected, actual = render_pair(source, known, dynamic, **options)
    assert_equal expected, actual
  end

  # --- basic folding --------------------------------------------------------

  def test_folds_plain_text_and_known_variables
    t = Liquid::Template.parse("Hello {{ tenant }}!").specialize(
      { 'tenant' => 'Acme' }
    )
    assert_equal "Hello Acme!", t.render!
    assert_equal "Hello Acme!", t.render!('tenant' => 'ignored')
  end

  def test_keeps_dynamic_variables
    assert_specializes_equally(
      "{{ tenant }}/{{ order.id }}",
      { 'tenant' => 'T' },
      { 'order' => { 'id' => 42 } }
    )
  end

  def test_nested_known_data
    assert_specializes_equally(
      "{{ config.app.name }} {{ order.id }}",
      { 'config' => { 'app' => { 'name' => 'Web' } } },
      { 'order' => { 'id' => 1 } }
    )
  end

  # --- pure filter counting: fixed parts compute exactly once --------------

  def test_pure_filter_runs_once_during_specialization
    source = "{{ tenant | count_upcase }}"
    Liquid::Template.parse(source).specialize(
      { 'tenant' => 'acme' }, pure_filters: [:count_upcase], filters: [CountingFilters]
    )
    assert_equal 1, CountingFilters.counters[:upcase]

    # Repeated rendering of the specialized template must not re-invoke it.
    specialized = Liquid::Template.parse(source).specialize(
      { 'tenant' => 'acme' }, pure_filters: [:count_upcase], filters: [CountingFilters]
    )
    CountingFilters.reset!
    5.times { specialized.render!(filters: [CountingFilters]) }
    assert_equal 0, CountingFilters.counters[:upcase]
  end

  def test_non_pure_filter_runs_per_render
    source = "{{ order.id | count_upcase }}"
    specialized = Liquid::Template.parse(source).specialize(
      {}, filters: [CountingFilters]
    )
    3.times do
      specialized.render!({ 'order' => { 'id' => 'a' } }, filters: [CountingFilters])
    end
    assert_equal 3, CountingFilters.counters[:upcase]
  end

  # --- unreachable branch errors must never be triggered -------------------

  def test_throwing_pure_filter_in_statically_dead_branch_never_runs
    source = "{% if config.enabled %}ok{% else %}{{ tenant | explode }}{% endif %}"
    specialized = Liquid::Template.parse(source).specialize(
      { 'config' => { 'enabled' => true }, 'tenant' => 'x' },
      pure_filters: [:explode], filters: [CountingFilters]
    )
    assert_equal "ok", specialized.render!(filters: [CountingFilters])
    assert_equal 0, CountingFilters.counters[:explode]
  end

  def test_throwing_pure_filter_behind_dynamic_condition_still_works
    # The condition is undecidable at specialize time; explode must not run
    # then, but must run (and raise) on renders where the branch executes.
    source = "{% if order.fail %}{{ tenant | explode }}{% else %}safe{% endif %}"
    specialized = Liquid::Template.parse(source).specialize(
      { 'tenant' => 'x' }, pure_filters: [:explode], filters: [CountingFilters]
    )
    assert_equal 0, CountingFilters.counters[:explode]

    assert_equal "safe", specialized.render!(
      { 'order' => { 'fail' => false } }, filters: [CountingFilters]
    )
    assert_equal 0, CountingFilters.counters[:explode]

    assert_raises(Liquid::ArgumentError) do
      specialized.render!({ 'order' => { 'fail' => true } }, filters: [CountingFilters])
    end
  end

  def test_throwing_pure_filter_inside_loop_never_runs_at_specialize
    source = "{% for item in order.items %}{{ tenant | explode }}{% endfor %}"
    specialized = Liquid::Template.parse(source).specialize(
      { 'tenant' => 'x' }, pure_filters: [:explode], filters: [CountingFilters]
    )
    assert_equal 0, CountingFilters.counters[:explode]

    # empty collection: never runs
    specialized.render!({ 'order' => { 'items' => [] } }, filters: [CountingFilters])
    assert_equal 0, CountingFilters.counters[:explode]

    # non-empty collection: runs once per element at render time
    3.times { CountingFilters.counters.delete(:explode) }
    CountingFilters.reset!
    assert_raises(Liquid::ArgumentError) do
      specialized.render!({ 'order' => { 'items' => [1, 2, 3] } }, filters: [CountingFilters])
    end
    assert_equal 1, CountingFilters.counters[:explode]
  end

  # --- conditions -----------------------------------------------------------

  def test_collapses_statically_true_and_false_branches
    t_true = Liquid::Template.parse("{% if f %}A{% else %}B{% endif %}").specialize('f' => true)
    t_false = Liquid::Template.parse("{% if f %}A{% else %}B{% endif %}").specialize('f' => false)
    assert_equal "A", t_true.render!
    assert_equal "B", t_false.render!
  end

  def test_preserves_dynamic_conditions
    assert_specializes_equally(
      "{% if order.premium %}P{% else %}R{% endif %}",
      {}, { 'order' => { 'premium' => true } }
    )
    assert_specializes_equally(
      "{% if order.premium %}P{% else %}R{% endif %}",
      {}, { 'order' => { 'premium' => false } }
    )
  end

  def test_static_condition_with_dynamic_body
    assert_specializes_equally(
      "{% if f %}{{ order.id }}{% endif %}",
      { 'f' => true }, { 'order' => { 'id' => 9 } }
    )
  end

  def test_and_or_short_circuit
    [
      "{% if false and order.x %}A{% endif %}",
      "{% if true or order.x %}A{% endif %}",
      "{% if a and order.f %}X{% endif %}",
      "{% if a or order.f %}X{% endif %}",
    ].each do |source|
      assert_specializes_equally(source, { 'a' => true }, { 'order' => {} })
      assert_specializes_equally(source, { 'a' => false }, { 'order' => { 'f' => true } })
    end
  end

  def test_unless
    assert_specializes_equally(
      "{% unless f %}a{% else %}b{% endunless %}",
      { 'f' => false }, {}
    )
    assert_specializes_equally(
      "{% unless f %}a{% elsif g %}b{% else %}c{% endunless %}",
      { 'f' => true, 'g' => true }, {}
    )
  end

  def test_comparison_error_in_unreachable_branch_is_not_triggered
    # 'string' == 1 raises at evaluation; the branch containing it must never
    # execute during specialization.
    source = "{% if f %}{{ tenant }}{% else %}{% if 'q' == 1 %}x{% endif %}{% endif %}"
    specialized = Liquid::Template.parse(source).specialize(
      { 'f' => true, 'tenant' => 'T' }
    )
    assert_equal "T", specialized.render!
  end

  def test_case
    assert_specializes_equally(
      "{% case c %}{% when 1 %}one{% when 2 %}two{% else %}other{% endcase %}",
      { 'c' => 2 }, {}
    )
    assert_specializes_equally(
      "{% case c %}{% when 1 %}one{% else %}other{% endcase %}",
      { 'c' => 9 }, {}
    )
    assert_specializes_equally(
      "{% case order.c %}{% when 1 %}one{% else %}other{% endcase %}",
      {}, { 'order' => { 'c' => 1 } }
    )
  end

  # --- loops and shadowing --------------------------------------------------

  def test_loops_are_preserved_with_dynamic_collections
    assert_specializes_equally(
      "{% for i in items %}[{{ i }}]{% endfor %}",
      {}, { 'items' => [1, 2, 3] }
    )
  end

  def test_known_values_inside_loops_are_folded_but_filter_is_not
    source = "{% for i in items %}{{ tenant | count_upcase }}{{ i }}{% endfor %}"
    specialized = Liquid::Template.parse(source).specialize(
      { 'tenant' => 't' }, pure_filters: [:count_upcase], filters: [CountingFilters]
    )
    CountingFilters.reset!
    output = specialized.render!({ 'items' => [1, 2] }, filters: [CountingFilters])
    assert_equal "T1T2", output
    assert_equal 2, CountingFilters.counters[:upcase]
  end

  def test_loop_variable_shadowing
    assert_specializes_equally(
      "{% assign n = 'outer' %}{% for n in items %}{{ n }}{% endfor %}{{ n }}",
      {}, { 'items' => ['a'] }
    )
  end

  def test_for_else
    assert_specializes_equally(
      "{% for i in items %}{{ i }}{% else %}none{% endfor %}",
      {}, { 'items' => [] }
    )
    assert_specializes_equally(
      "{% for i in items %}{{ i }}{% else %}none{% endfor %}",
      {}, { 'items' => [1] }
    )
  end

  # --- assign and capture ---------------------------------------------------

  def test_static_assign
    source = "{% assign x = tenant | count_upcase %}{{ x }}"
    specialized = Liquid::Template.parse(source).specialize(
      { 'tenant' => 'hi' }, pure_filters: [:count_upcase], filters: [CountingFilters]
    )
    assert_equal "HI", specialized.render!
    assert_equal 1, CountingFilters.counters[:upcase]
  end

  def test_dynamic_assign
    assert_specializes_equally(
      "{% assign x = order.id %}{{ x }}",
      {}, { 'order' => { 'id' => 3 } }
    )
  end

  def test_assignment_inside_dynamic_conditional
    assert_specializes_equally(
      "{% if order.f %}{% assign y = tenant %}{% endif %}{{ y }}",
      { 'tenant' => 'Q' }, { 'order' => { 'f' => true } }
    )
    assert_specializes_equally(
      "{% if order.f %}{% assign y = tenant %}{% endif %}{{ y }}",
      { 'tenant' => 'Q' }, { 'order' => { 'f' => false } }
    )
  end

  def test_static_capture
    assert_specializes_equally(
      "{% capture x %}Hi {{ tenant }}{% endcapture %}{{ x }}",
      { 'tenant' => 'Z' }, {}
    )
  end

  def test_dynamic_capture
    assert_specializes_equally(
      "{% capture x %}{{ order.id }}{% endcapture %}{{ x }}",
      {}, { 'order' => { 'id' => 5 } }
    )
  end

  # --- filter purity enforcement -------------------------------------------

  def test_undeclared_pure_filter_is_not_invoked_at_specialize
    count = 0
    mod = Module.new do
      define_method(:side) do |input|
        count += 1
        input
      end
    end
    Liquid::Environment.default.register_filter(mod)
    Liquid::Template.parse("{{ x | side }}").specialize({ 'x' => 'a' })
    assert_equal 0, count
  end

  def test_unknown_pure_filter_name_raises
    assert_raises(Liquid::UndefinedFilter) do
      Liquid::Template.parse("{{ x }}").specialize(
        { 'x' => 1 }, pure_filters: [:not_registered_filter]
      )
    end
  end

  def test_non_plain_data_rejected
    assert_raises(Liquid::ArgumentError) do
      Liquid::Template.parse("{{ x }}").specialize({ 'x' => Object.new })
    end
    assert_raises(Liquid::ArgumentError) do
      Liquid::Template.parse("{{ x }}").specialize({ 'x' => Class.new(Liquid::Drop).new })
    end
  end

  def test_callers_data_is_not_mutated
    known = { 'a' => [1, { 'b' => 2 }], 's' => 'x' }
    Liquid::Template.parse("{{ a[0] }}").specialize(known)
    assert_equal({ 'a' => [1, { 'b' => 2 }], 's' => 'x' }, known)
  end

  # --- resource limits ------------------------------------------------------

  def test_resource_limit_render_score_parity
    source = "{% if f %}A{{ x }}B{% else %}C{% endif %}{% for i in items %}{{ i }}{% endfor %}"
    [
      {},
      { render_score_limit: 1000 },
      { assign_score_limit: 1 },
      { render_length_limit: 2 },
      { render_length_limit: 1000 },
    ].each do |limits|
      t1 = Liquid::Template.parse(source)
      t1.instance_variable_set(:@resource_limits, Liquid::ResourceLimits.new(limits))
      t1.render({ 'f' => true, 'x' => 'X', 'items' => [1, 2] }) rescue Liquid::MemoryError

      t2 = Liquid::Template.parse(source)
      specialized = t2.specialize({ 'f' => true, 'x' => 'X' })
      specialized.instance_variable_set(:@resource_limits, Liquid::ResourceLimits.new(limits))
      specialized.render({ 'items' => [1, 2] }) rescue Liquid::MemoryError

      assert_equal t1.resource_limits.render_score, specialized.resource_limits.render_score
      assert_equal t1.resource_limits.reached?, specialized.resource_limits.reached?
    end
  end

  def test_resource_limit_threshold_parity
    # Both templates must enforce the same render-score budget: neither
    # completes when the budget is below the required score, and both complete
    # when it covers it.
    source = "{% if f %}A{{ x }}B{% else %}C{% endif %}"
    required = 4

    [required - 1, required].each do |budget|
      limits = { render_score_limit: budget }

      orig_raised = false
      t1 = Liquid::Template.parse(source)
      t1.instance_variable_set(:@resource_limits, Liquid::ResourceLimits.new(limits))
      begin
        t1.render({ 'f' => true, 'x' => 'X' })
      rescue Liquid::MemoryError
        orig_raised = true
      end

      spec_raised = false
      specialized = Liquid::Template.parse(source).specialize({ 'f' => true, 'x' => 'X' })
      specialized.instance_variable_set(:@resource_limits, Liquid::ResourceLimits.new(limits))
      begin
        specialized.render({})
      rescue Liquid::MemoryError
        spec_raised = true
      end

      assert_equal orig_raised, spec_raised,
        "raise parity for render_score_limit=#{budget}"
    end
  end

  def test_cumulative_render_score_parity_across_renders
    source = "{% if f %}A{% endif %}{{ x }}"
    limits = { cumulative_render_score_limit: 10 }

    t1 = Liquid::Template.parse(source)
    t1.instance_variable_set(:@resource_limits, Liquid::ResourceLimits.new(limits))
    s1 = Liquid::Template.parse(source).specialize({ 'f' => true })
    s1.instance_variable_set(:@resource_limits, Liquid::ResourceLimits.new(limits))

    orig_error = spec_error = :none
    4.times { t1.render('f' => true, 'x' => 'k') rescue orig_error = Liquid::MemoryError }
    4.times { s1.render('x' => 'k') rescue spec_error = Liquid::MemoryError }

    assert_equal(orig_error == Liquid::MemoryError, spec_error == Liquid::MemoryError)
    assert_equal(t1.resource_limits.cumulative_render_score,
      s1.resource_limits.cumulative_render_score)
  end

  # --- template independence ------------------------------------------------

  def test_specialize_returns_new_template_and_keeps_original
    original = Liquid::Template.parse("{{ x }}")
    specialized = original.specialize({ 'x' => 'Q' })
    refute_same original, specialized
    assert_equal "R", original.render!('x' => 'R')
    assert_equal "Q", specialized.render!
  end

  def test_specialized_template_still_renders_with_variables
    t = Liquid::Template.parse("{{ t }}{% if b %}A{% endif %}").specialize('b' => true)
    ctx = Liquid::Context.new({ 't' => 'Z' })
    assert_equal "ZA", t.render(ctx)
  end

  # The core specialization guarantee demonstrated on a tenant-style
  # template rendered against many dynamic records:
  #   * a counting filter in the fixed part runs once total (not per render)
  #   * a throwing filter in a statically unreachable branch never runs
  #   * a throwing filter behind a dynamic condition runs per reachable render
  def test_fixed_part_computes_once_and_unreachable_branch_never_errors
    source = <<~'LIQUID'
      {% if tenant.active %}{{ tenant.name | count_upcase }}{% else %}{{ tenant.name | explode }}{% endif %}
      {% for line in order.lines %}{{ line.sku }}{% endfor %}
    LIQUID
    known = { 'tenant' => { 'name' => 'acme', 'active' => true } }

    specialized = Liquid::Template.parse(source).specialize(
      known,
      pure_filters: [:count_upcase, :explode],
      filters: [CountingFilters]
    )

    assert_equal 1, CountingFilters.counters[:upcase]
    assert_equal 0, CountingFilters.counters[:explode]

    CountingFilters.reset!
    100.times do
      specialized.render!(
        { 'order' => { 'lines' => [{ 'sku' => 'A' }, { 'sku' => 'B' }] } },
        filters: [CountingFilters]
      )
    end

    assert_equal 0, CountingFilters.counters[:upcase]
    assert_equal 0, CountingFilters.counters[:explode]

    # Compare against the original over the same 100 records.
    CountingFilters.reset!
    original = Liquid::Template.parse(source)
    100.times do
      original.render!(
        known.merge('order' => { 'lines' => [{ 'sku' => 'A' }, { 'sku' => 'B' }] }),
        filters: [CountingFilters]
      )
    end
    assert_equal 100, CountingFilters.counters[:upcase]
    assert_equal 0, CountingFilters.counters[:explode]
  end

  def test_throwing_pure_filter_runs_per_reachable_render_in_dynamic_condition
    source = "{% if order.fail %}{{ x | explode }}{% endif %}"
    specialized = Liquid::Template.parse(source).specialize(
      { 'x' => 1 }, pure_filters: [:explode], filters: [CountingFilters]
    )
    assert_equal 0, CountingFilters.counters[:explode]

    specialized.render!({ 'order' => { 'fail' => false } }, filters: [CountingFilters])
    specialized.render!({ 'order' => { 'fail' => false } }, filters: [CountingFilters])
    assert_equal 0, CountingFilters.counters[:explode]

    assert_raises(Liquid::ArgumentError) do
      specialized.render!({ 'order' => { 'fail' => true } }, filters: [CountingFilters])
    end
    assert_equal 1, CountingFilters.counters[:explode]
  end
end
