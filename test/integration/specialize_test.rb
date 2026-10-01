# frozen_string_literal: true

require 'test_helper'

# Counting and error-raising filters used to prove specialization evaluates
# fixed parts exactly once and never touches unreachable branches.
module SpecializationTestFilters
  def self.reset_counters!
    counters.clear
  end

  def self.counters
    @counters ||= Hash.new(0)
  end

  def count(input, key)
    SpecializationTestFilters.counters[key.to_s] += 1
    input
  end

  def upcase_it(input)
    input.to_s.upcase
  end

  def suffix(input, suffix)
    "#{input}#{suffix}"
  end

  def explode(input)
    raise Liquid::ArgumentError, "explode must not be called"
  end
end

class SpecializeTest < Minitest::Test
  include Liquid

  PURE_FILTERS = %w[count upcase_it suffix explode].freeze

  def setup
    Liquid::Environment.default.register_filter(SpecializationTestFilters)
    SpecializationTestFilters.reset_counters!
  end

  def render_pair(source, known, dynamic, render_options = {})
    template = Liquid::Template.parse(source)
    specialized = template.specialize(
      known,
      pure_filters: PURE_FILTERS,
      filters: [SpecializationTestFilters]
    )
    options = { filters: [SpecializationTestFilters] }.merge(render_options)
    original = template.render(known.merge(dynamic), **options)
    specialized_output = specialized.render(dynamic, **options)
    [original, specialized_output, template, specialized]
  end

  def assert_specializes_equivalently(source, known, dynamic = {}, **render_options)
    original, specialized, = render_pair(source, known, dynamic, render_options)
    assert_equal(original, specialized)
  end

  def test_folds_plain_known_text_and_variables
    source = "Hello {{ tenant.name }}, host={{ config.host }}"
    template = Template.parse(source)
    specialized = template.specialize(
      { 'tenant' => { 'name' => 'Acme' }, 'config' => { 'host' => 'h1' } }
    )
    assert_equal("Hello Acme, host=h1", specialized.render!)
  end

  def test_dynamic_variables_survive
    assert_specializes_equivalently(
      "{{ a }}-{{ b }}",
      { 'a' => 'fixed' },
      { 'b' => 'dynamic' }
    )
  end

  def test_unknown_root_variable_is_not_folded
    source = "{{ a }}"
    template = Template.parse(source)
    specialized = template.specialize({})
    assert_equal("x", specialized.render!('a' => 'x'))
    assert_equal("", specialized.render!)
  end

  def test_pure_filter_is_evaluated_once_during_specialization
    source = "{{ tenant | count: 'tenant' }}{% for order in orders %}{{ order.id | count: 'order' }}{% endfor %}"
    known = { 'tenant' => 'Acme' }
    template = Template.parse(source)
    specialized = nil
    SpecializationTestFilters.reset_counters!
    specialized = template.specialize(
      known, pure_filters: PURE_FILTERS, filters: [SpecializationTestFilters]
    )
    assert_equal(1, SpecializationTestFilters.counters['tenant'])
    1000.times { |i| specialized.render!({ 'orders' => [{ 'id' => i }] }, filters: [SpecializationTestFilters]) }
    assert_equal(1, SpecializationTestFilters.counters['tenant'])
    assert_equal(1000, SpecializationTestFilters.counters['order'])
  end

  def test_original_evaluates_fixed_filter_every_render
    source = "{{ tenant | count: 'tenant' }}"
    template = Template.parse(source)
    SpecializationTestFilters.reset_counters!
    10.times { template.render!({ 'tenant' => 'A' }, filters: [SpecializationTestFilters]) }
    assert_equal(10, SpecializationTestFilters.counters['tenant'])
  end

  def test_unpure_filter_is_not_called_during_specialization
    source = "{{ tenant | count: 'nope' }}"
    template = Template.parse(source)
    SpecializationTestFilters.reset_counters!
    # Without declaring it pure, the filter survives and runs per render.
    specialized = template.specialize({ 'tenant' => 'A' }, filters: [SpecializationTestFilters])
    assert_equal(0, SpecializationTestFilters.counters['nope'])
    specialized.render!({}, filters: [SpecializationTestFilters])
    assert_equal(1, SpecializationTestFilters.counters['nope'])
  end

  def test_declaring_unknown_pure_filter_raises
    template = Template.parse("{{ a }}")
    error = assert_raises(ArgumentError) do
      template.specialize({ 'a' => 1 }, pure_filters: ['not_a_filter'])
    end
    assert_match(/not_a_filter/, error.message)
  end

  def test_static_true_branch_is_folded_false_branch_dropped
    source = "{% if config.flag %}T{% else %}F{% endif %}"
    assert_equal("T", Template.parse(source).specialize({ 'config' => { 'flag' => true } }).render!)
    assert_equal("F", Template.parse(source).specialize({ 'config' => { 'flag' => false } }).render!)
  end

  def test_dynamic_condition_keeps_both_branches
    assert_specializes_equivalently(
      "{% if f %}T{% else %}F{% endif %}",
      {},
      { 'f' => true }
    )
    assert_specializes_equivalently(
      "{% if f %}T{% else %}F{% endif %}",
      {},
      { 'f' => false }
    )
  end

  def test_unless_static_conditions
    source = "{% unless f %}U{% endunless %}"
    assert_equal("", Template.parse(source).specialize({ 'f' => true }).render!)
    assert_equal("U", Template.parse(source).specialize({ 'f' => false }).render!)
  end

  def test_elsif_and_boolean_operators
    templates = [
      "{% if a == 1 %}1{% elsif a == 2 %}2{% else %}x{% endif %}",
      "{% if a and b %}AB{% else %}no{% endif %}",
      "{% if a or b %}AB{% else %}no{% endif %}",
    ]
    data_sets = [
      [{ 'a' => 1, 'b' => true }, { 'a' => 2, 'b' => false }, { 'a' => false, 'b' => true }],
      [{ 'a' => true, 'b' => true }, { 'a' => true, 'b' => false }, { 'a' => false, 'b' => true }],
      [{ 'a' => true, 'b' => false }, { 'a' => false, 'b' => true }, { 'a' => false, 'b' => false }],
    ]
    templates.each_with_index do |source, i|
      data_sets[i].each { |data| assert_specializes_equivalently(source, data, {}) }
    end
  end

  def test_unreachable_throwing_branch_never_executes
    # Throwing filter lives in the branch that never renders.
    source = "{% if config.flag %}{{ order.id }}{% else %}{{ x | explode }}{% endif %}"
    template = Template.parse(source)
    SpecializationTestFilters.reset_counters!
    specialized = template.specialize(
      { 'config' => { 'flag' => true } },
      pure_filters: PURE_FILTERS, filters: [SpecializationTestFilters]
    )
    assert_equal("7", specialized.render!({ 'order' => { 'id' => 7 } }, filters: [SpecializationTestFilters]))
    assert_equal(0, SpecializationTestFilters.counters['explode'])

    source2 = "{% if config.flag %}{{ x | explode }}{% else %}ok{% endif %}"
    specialized2 = Template.parse(source2).specialize(
      { 'config' => { 'flag' => false } },
      pure_filters: PURE_FILTERS, filters: [SpecializationTestFilters]
    )
    SpecializationTestFilters.reset_counters!
    assert_equal("ok", specialized2.render!({ 'x' => 1 }, filters: [SpecializationTestFilters]))
    assert_equal(0, SpecializationTestFilters.counters['explode'])
  end

  def test_throwing_filter_in_empty_loop_body_never_executes
    source = "{% for i in items %}{{ i | explode }}{% endfor %}"
    template = Template.parse(source)
    specialized = template.specialize(
      {}, pure_filters: PURE_FILTERS, filters: [SpecializationTestFilters]
    )
    SpecializationTestFilters.reset_counters!
    assert_equal("", specialized.render!({ 'items' => [] }, filters: [SpecializationTestFilters]))
    assert_equal(0, SpecializationTestFilters.counters['explode'])
  end

  def test_loops_are_never_folded
    source = "{% for i in items %}{{ i }}{% endfor %}"
    assert_specializes_equivalently(source, {}, { 'items' => [1, 2, 3] })
    assert_specializes_equivalently(source, { 'items' => [7, 8] }, {})
  end

  def test_for_loop_limit_offset_and_empty_else
    [
      "{% for i in items limit: 2 offset: 1 %}{{ i }}{% endfor %}",
      "{% for i in items %}{{ i }}{% else %}none{% endfor %}",
      "{% for i in (1..3) %}{{ i }}{% endfor %}",
      "{% for i in (a..b) %}{{ i }}{% endfor %}",
    ].each do |source|
      assert_specializes_equivalently(source, {}, { 'items' => [1, 2, 3, 4], 'a' => 1, 'b' => 2 })
      assert_specializes_equivalently(source, {}, { 'items' => [] })
    end
  end

  def test_loop_variable_shadows_outer_binding
    source = "{% assign x = 'outer' %}{% for i in items %}{{ x }}{% endfor %}{{ x }}"
    assert_specializes_equivalently(source, {}, { 'items' => [1, 2], 'x' => 'dyn' })
    source2 = "{% for tenant in items %}{{ tenant }}{% endfor %}{{ tenant }}"
    assert_specializes_equivalently(source2, { 'tenant' => 'T' }, { 'items' => %w[x y] })
  end

  def test_assign_leakage_through_conditions
    source = "{% if c %}{% assign x = 1 %}{% endif %}[{{ x }}]"
    assert_specializes_equivalently(source, { 'c' => true }, {})
    assert_specializes_equivalently(source, { 'c' => false }, {})
    assert_specializes_equivalently(source, {}, { 'c' => true })
    assert_specializes_equivalently(source, {}, { 'c' => false })
  end

  def test_assign_in_both_branches
    source = "{% if f %}{% assign x = 1 %}{% else %}{% assign x = 2 %}{% endif %}{{ x }}"
    assert_specializes_equivalently(source, {}, { 'f' => true })
    assert_specializes_equivalently(source, {}, { 'f' => false })
    assert_specializes_equivalently(source, { 'f' => true }, {})
    assert_specializes_equivalently(source, { 'f' => false }, {})
  end

  def test_static_assign_is_reused_inside_loops
    source = "{% assign base = config.host %}{% for order in orders %}{{ order.id }}@{{ base }};{% endfor %}"
    assert_specializes_equivalently(
      source,
      { 'config' => { 'host' => 'h' } },
      { 'orders' => [{ 'id' => 1 }, { 'id' => 2 }] }
    )
  end

  def test_capture_static_and_dynamic
    assert_specializes_equivalently(
      "{% capture g %}hello {{ tenant }}{% endcapture %}{{ g }}",
      { 'tenant' => 'A' }, {}
    )
    assert_specializes_equivalently(
      "{% capture g %}{{ order.id }}{% endcapture %}{{ g }}",
      {}, { 'order' => { 'id' => 9 } }
    )
    assert_specializes_equivalently(
      "{% capture g %}{% for i in items %}{{ i }}{% endfor %}{% endcapture %}[{{ g }}]",
      {}, { 'items' => [1, 2] }
    )
  end

  def test_case_specialization
    source = "{% case mode %}{% when 1 %}one{% when 2 %}two{% else %}other{% endcase %}"
    assert_specializes_equivalently(source, { 'mode' => 2 }, {})
    assert_specializes_equivalently(source, { 'mode' => 3 }, {})
    assert_specializes_equivalently(source, {}, { 'mode' => 1 })
    assert_specializes_equivalently(source, {}, { 'mode' => 9 })
  end

  def test_nested_conditions_and_loops
    source = "{% if f %}{% for i in items %}[{{ i }}-{{ tenant }}]{% endfor %}{% endif %}"
    assert_specializes_equivalently(source, { 'f' => true, 'tenant' => 'T' }, { 'items' => %w[a b] })
    assert_specializes_equivalently(source, { 'f' => false, 'tenant' => 'T' }, { 'items' => %w[a b] })
  end

  def test_size_first_last_commands
    assert_specializes_equivalently("{{ items.first }}/{{ items.last }}/{{ items.size }}",
      { 'items' => [1, 2, 3] }, {})
    assert_specializes_equivalently("{{ items.first }}", {}, { 'items' => [5] })
  end

  def test_render_score_limit_parity
    source = "{{ tenant }}{% for i in items %}[{{ i }}]{% endfor %}"
    [1, 2, 5, 10].each do |limit|
      template = Template.parse(source)
      specialized = template.specialize({ 'tenant' => 'T' })
      template.resource_limits.render_score_limit = limit
      specialized.resource_limits.render_score_limit = limit
      original_result = begin
        template.render!('tenant' => 'T', 'items' => [1, 2, 3, 4])
      rescue MemoryError
        :memory
      end
      specialized_result = begin
        specialized.render!('items' => [1, 2, 3, 4])
      rescue MemoryError
        :memory
      end
      assert_equal(original_result, specialized_result, "render_score_limit=#{limit}")
    end
  end

  def test_render_length_limit_parity
    source = "AAAA{{ tenant }}BBBB"
    [4, 8, 10, 100].each do |limit|
      template = Template.parse(source)
      specialized = template.specialize({ 'tenant' => 'XX' })
      template.resource_limits.render_length_limit = limit
      specialized.resource_limits.render_length_limit = limit
      original_result = begin
        template.render!('tenant' => 'XX')
      rescue MemoryError
        :memory
      end
      specialized_result = begin
        specialized.render!
      rescue MemoryError
        :memory
      end
      assert_equal(original_result, specialized_result, "render_length_limit=#{limit}")
    end
  end

  def test_assign_score_limit_parity
    source = "{% assign big = tenant.s %}{% for i in items %}{{ big }}{% endfor %}"
    [10, 49, 50, 1000].each do |limit|
      template = Template.parse(source)
      specialized = template.specialize({ 'tenant' => { 's' => 'X' * 50 } })
      template.resource_limits.assign_score_limit = limit
      specialized.resource_limits.assign_score_limit = limit
      original_result = begin
        template.render!('tenant' => { 's' => 'X' * 50 }, 'items' => [1])
      rescue MemoryError
        :memory
      end
      specialized_result = begin
        specialized.render!('items' => [1])
      rescue MemoryError
        :memory
      end
      assert_equal(original_result, specialized_result, "assign_score_limit=#{limit}")
    end
  end

  def test_cumulative_render_score_parity
    source = "{{ tenant }}{% for i in items %}{{ i }}{% endfor %}"
    template = Template.parse(source)
    specialized = template.specialize({ 'tenant' => 'T' })
    template.resource_limits.cumulative_render_score_limit = 20
    specialized.resource_limits.cumulative_render_score_limit = 20
    original_count = 0
    specialized_count = 0
    begin
      10.times { template.render!('tenant' => 'T', 'items' => [1, 2]); original_count += 1 }
    rescue MemoryError
    end
    begin
      10.times { specialized.render!('items' => [1, 2]); specialized_count += 1 }
    rescue MemoryError
    end
    assert_equal(original_count, specialized_count)
  end

  def test_error_message_and_line_number_parity
    source = "{% for x in items %}{{ x }}\n{% endfor %}\n{{ a | suffix: b }}"
    known = {}
    dynamic = { 'items' => [1, 2], 'a' => 'A' }
    template = Template.parse(source, line_numbers: true)
    specialized = template.specialize(
      known, pure_filters: PURE_FILTERS, filters: [SpecializationTestFilters]
    )
    original = template.render(known.merge(dynamic), filters: [SpecializationTestFilters])
    specialized_output = specialized.render(dynamic, filters: [SpecializationTestFilters])
    assert_equal(original, specialized_output)
    assert_equal(
      template.errors.map { |e| [e.class, e.line_number, e.message] },
      specialized.errors.map { |e| [e.class, e.line_number, e.message] }
    )
  end

  def test_drops_are_never_invoked_during_specialization
    drop_class = Class.new(Liquid::Drop) do
      def initialize(target)
        super()
        @target = target
      end

      def name
        @target[:name]
      end
    end

    source = "{{ d.name }}-{{ a }}"
    template = Template.parse(source)
    # A Drop in the known data is ignored (not plain data); the variable
    # survives and the Drop is evaluated per render.
    drop = drop_class.new(name: 'D')
    specialized = template.specialize({ 'd' => drop, 'a' => 'A' })
    assert_equal("D-A", specialized.render!('d' => drop_class.new(name: 'D')))
  end

  def test_increment_is_preserved_per_render
    source = "{% increment ctr %}"
    template = Template.parse(source)
    specialized = template.specialize({ 'ctr' => 4 })
    assert_equal("4", specialized.render!)
    # renders are isolated: no cross-render leakage of counter state
    assert_equal("4", specialized.render!)
    assert_equal("4", template.render!('ctr' => 4))
  end

  def test_raw_and_other_tags_survive
    assert_specializes_equivalently("{% raw %}{{ arr }}{% endraw %}", { 'arr' => [1] }, {})
    assert_specializes_equivalently("{% increment k %}{% increment k %}", {}, {})
    assert_specializes_equivalently("{% decrement k %}", {}, {})
    assert_specializes_equivalently("{% for i in items %}{% cycle 'a','b' %}{% endfor %}",
      {}, { 'items' => [1, 2, 3] })
    assert_specializes_equivalently(
      "{% for i in items %}{% if i == 2 %}{% break %}{% endif %}{{ i }}{% endfor %}",
      {}, { 'items' => [1, 2, 3] }
    )
  end

  def test_specialized_template_keeps_name
    template = Template.parse("{{ a }}")
    template.name = "order_template"
    specialized = template.specialize({})
    assert_equal("order_template", specialized.name)
  end

  def test_specialize_without_parse_raises
    template = Template.new
    assert_raises(RuntimeError) { template.specialize({}) }
  end

  def test_original_template_remains_usable_after_specialize
    source = "{{ a }}|{{ b }}"
    template = Template.parse(source)
    specialized = template.specialize({ 'a' => 'x' })
    assert_equal("x|y", specialized.render!('b' => 'y'))
    assert_equal("p|q", template.render!('a' => 'p', 'b' => 'q'))
    assert_equal("x|z", specialized.render!('b' => 'z'))
  end

  def test_strict_variables_parity
    source = "{{ a }}{{ missing }}"
    template = Template.parse(source)
    specialized = template.specialize({ 'a' => 1 })
    original_error = assert_raises(UndefinedVariable) { template.render!({ 'a' => 1 }, {}, strict_variables: true) }
    specialized_error = assert_raises(UndefinedVariable) { specialized.render!({}, {}, strict_variables: true) }
    assert_equal(original_error.message, specialized_error.message)
  end

  def test_strict_filters_parity_for_unknown_surviving_filter
    source = "{{ a | bogus }}"
    template = Template.parse(source)
    # bogus is not declared pure, so it survives specialization
    specialized = template.specialize({ 'a' => 1 }, filters: [SpecializationTestFilters])
    assert_raises(UndefinedFilter) { template.render!({ 'a' => 1 }, strict_filters: true) }
    assert_raises(UndefinedFilter) { specialized.render!({ 'a' => 1 }, strict_filters: true) }
  end
end

class SpecializeMiscTest < Minitest::Test
  include Liquid

  def test_empty_and_text_only_templates
    assert_equal("", Template.parse("").specialize({}).render!)
    assert_equal("just text", Template.parse("just text").specialize({}).render!)
  end

  def test_nested_and_bracket_lookups
    assert_equal("9", Template.parse("{{ a.b[0] }}").specialize({ 'a' => { 'b' => [9] } }).render!)
    assert_equal("1", Template.parse("{{ m['x'] }}").specialize({ 'm' => { 'x' => 1 } }).render!)
    assert_equal(
      "1",
      Template.parse("{{ m[k] }}").specialize({ 'm' => { 'x' => 1 } }).render!('k' => 'x')
    )
  end

  def test_static_range_in_loop
    source = "{% for i in (cfg.s..cfg.e) %}{{ i }}{% endfor %}"
    specialized = Template.parse(source).specialize({ 'cfg' => { 's' => 1, 'e' => 3 } })
    assert_equal("123", specialized.render!)
  end

  def test_assign_leaks_out_of_loop
    source = "{% for i in items %}{% assign x = 'K' %}{{ x }}{% endfor %}{{ x }}"
    assert_specializes(source, {}, { 'items' => [1, 2] }, "KKK")
  end

  def test_loop_variable_does_not_shadow_assign_leak
    source = "{% for x in items %}{{ x }}{% endfor %}[{{ x }}]"
    assert_specializes(source, {}, { 'items' => [1, 2] }, "12[]")
  end

  def test_deeply_nested_conditions_and_loops
    source = <<~LIQUID
      {% for o in orders %}{% if o.vip %}V{% if cfg.tier == 2 %}2{% else %}1{% endif %}{% else %}R{% endif %}
      {{ o.id }}{% for t in o.tags %}[{{ t }}-{{ tenant }}]{% endfor %}{% endfor %}
    LIQUID
    data = {
      'tenant' => 'Acme',
      'cfg' => { 'tier' => 2 },
      'orders' => [
        { 'id' => 1, 'vip' => true, 'tags' => %w[a] },
        { 'id' => 2, 'vip' => false, 'tags' => [] },
      ],
    }
    expected = Template.parse(source).render!(data)
    assert_specializes(source, { 'tenant' => 'Acme', 'cfg' => { 'tier' => 2 } },
      { 'orders' => data['orders'] }, expected)
  end

  private

  def assert_specializes(source, known, dynamic, expected)
    template = Template.parse(source)
    specialized = template.specialize(known)
    assert_equal(expected, specialized.render!(dynamic))
    assert_equal(expected, template.render!(known.merge(dynamic)))
  end
end
