# frozen_string_literal: true

require 'test_helper'

module PreprocessSideFilter
  def dangerous(input)
    raise 'must not run during preprocessing'
  end
end

class PartialEvaluationUnitTest < Minitest::Test
  include Liquid

  BRAND = {
    'name' => 'Acme',
    'vip' => true,
    'n' => 2,
    'tags' => %w[a b],
    'empty_tags' => [],
    'color' => 'red',
  }.freeze

  # Asserts that specializing +source+ against +known+ yields a residual
  # template that is output- and error-equivalent to the original for every
  # assignment in +remainder_sets+.
  def assert_equivalent(source, known, remainder_sets = [{}], options = {})
    original = Template.parse(source, options)
    residual = original.specialize(known, options)
    remainder_sets.each do |remainder|
      assigns = deep_copy(known.merge(remainder))
      expected = render_pair(original, assigns)
      assigns2 = deep_copy(known.merge(remainder))
      actual = render_pair(residual, assigns2)
      assert_equal(expected, actual, lambda {
        "equivalence failed for #{source.inspect} with #{assigns2.inspect}"
      })
    end
    residual
  end

  def render_pair(template, assigns)
    template.render!(assigns)
  rescue Liquid::Error => e
    [:raise, e.class]
  end

  def deep_copy(value)
    Marshal.load(Marshal.dump(value))
  end

  def remainder_sets
    [
      {},
      { 'customer' => { 'name' => 'Sam', 'age' => 30 } },
      { 'customer' => { 'name' => '', 'age' => 0 } },
      { 'items' => [1, 2, 3] },
    ]
  end

  def test_folds_known_variables_and_pure_filters
    residual = assert_equivalent(
      'Hi {{ brand.name | upcase }} {{ customer.name }}',
      { 'brand' => BRAND }, remainder_sets,
    )
    nodes = residual.root.nodes
    assert(nodes.any? { |node| node.is_a?(StaticOutput) && node.value == 'ACME' })
    assert_equal('Hi {{ "ACME" }} {{ customer.name }}', residual.residual_source)
    assert_equal([' customer.name '], residual.specialization_info.expressions)
  end

  def test_constant_folding_without_known_variables
    residual = Template.parse('{{ "x" | upcase }}').specialize({})
    assert_equal('X', residual.render!)
  end

  def test_decidable_branch_is_collapsed
    residual = assert_equivalent(
      '{% if brand.vip %}VIP {{ customer.name }}{% else %}no{% endif %}',
      { 'brand' => BRAND }, remainder_sets,
    )
    refute(residual.root.nodes.any? { |node| node.is_a?(If) })
    assert_includes(residual.residual_source, 'VIP ')
  end

  def test_unknown_branch_is_fully_retained
    source = '{% if customer.name %}HAS{% else %}NONE{% endif %}'
    residual = assert_equivalent(source, {}, remainder_sets)
    assert_equal(1, residual.root.nodes.count { |node| node.is_a?(If) })
    assert_equal(['customer.name'], residual.specialization_info.expressions)
    assert_equal('HAS', residual.render!('customer' => { 'name' => 'Sam' }))
    assert_equal('NONE', residual.render!('customer' => { 'name' => nil }))
  end

  def test_unknown_branch_not_deleted_from_sample_input
    # A single sample must never pin the unknowable branch.
    source = '{% if vip %}{{ customer.name }}{% endif %}'
    residual = Template.parse(source).specialize('vip' => true)
    other = Template.parse(source).specialize('vip' => false)
    assert_equal('Pat', residual.render!('customer' => { 'name' => 'Pat' }))
    assert_equal('', other.render!('customer' => { 'name' => 'whatever' }))
    assert_equal('Kim', residual.render!('customer' => { 'name' => 'Kim' }))
  end

  def test_unless_and_elsif
    [
      '{% unless brand.vip %}X{% else %}Y{% endunless %}',
      '{% if brand.n > 1 %}big{% elsif brand.n == 1 %}one{% else %}zero{% endif %}',
      '{% if brand.vip and customer.name %}BOTH{% else %}NO{% endif %}',
      '{% if brand.vip or customer.name %}EITHER{% endif %}',
    ].each { |source| assert_equivalent(source, { 'brand' => BRAND }, remainder_sets) }
  end

  def test_case_equivalence
    assert_equivalent(
      '{% case brand.color %}{% when "red" %}R{% else %}?{% endcase %}',
      { 'brand' => BRAND }, remainder_sets,
    )
    assert_equivalent(
      '{% case customer.name %}{% when "Sam" %}S{% else %}?{% endcase %}',
      { 'brand' => BRAND }, remainder_sets,
    )
  end

  def test_known_finite_loop_is_unrolled
    residual = assert_equivalent(
      '{% for t in brand.tags %}[{{ t | upcase }}]{% endfor %}',
      { 'brand' => BRAND }, remainder_sets,
    )
    refute(residual.root.nodes.any? { |node| node.is_a?(For) })
    assert_includes(residual.residual_source, '[{{ "A" }}]')
  end

  def test_loop_over_unknown_collection_is_retained
    source = '{% for i in items %}{{ i }}:{{ brand.n }};{% endfor %}'
    residual = assert_equivalent(source, { 'brand' => BRAND }, remainder_sets)
    assert(residual.root.nodes.any? { |node| node.is_a?(For) })
  end

  def test_loop_with_forloop_dependency_is_retained
    source = '{% for i in (1..brand.n) %}{{ forloop.index }}{% endfor %}'
    residual = assert_equivalent(source, { 'brand' => BRAND }, remainder_sets)
    assert(residual.root.nodes.any? { |node| node.is_a?(For) })
    assert_equal('12', residual.render!('brand' => BRAND))
  end

  def test_loop_break_continue_is_retained
    %w[break continue].each do |keyword|
      source = "{% for i in (1..brand.n) %}{% #{keyword} %}{% endfor %}X"
      assert_equivalent(source, { 'brand' => BRAND }, remainder_sets)
    end
  end

  def test_empty_known_loop_renders_else
    assert_equivalent(
      '{% for t in brand.empty_tags %}x{% else %}EMPTY{% endfor %}',
      { 'brand' => BRAND }, remainder_sets,
    )
  end

  def test_assign_and_capture_folding
    assert_equivalent(
      '{% assign g = brand.name | upcase %}{{ g }}/{{ customer.name }}',
      { 'brand' => BRAND }, remainder_sets,
    )
    assert_equivalent(
      '{% capture slogan %}Buy {{ brand.name }}{% endcapture %}{{ slogan }}',
      { 'brand' => BRAND }, remainder_sets,
    )
  end

  def test_partial_filter_chain
    residual = assert_equivalent(
      '{{ brand.name | upcase | customer_filter }}',
      { 'brand' => BRAND }, remainder_sets,
    )
    assert_includes(residual.residual_source, '| customer_filter')
  end

  def test_non_pure_filter_is_never_run_during_preprocessing
    env = Environment.build { |e| e.register_filter(PreprocessSideFilter) }
    template = Template.parse('{{ brand.name | dangerous }}', environment: env)
    residual = template.specialize({ 'brand' => BRAND }, environment: env)
    assert_equal(1, residual.specialization_info.retained_count)
  end

  class TrackingDrop < Liquid::Drop
    attr_reader :calls

    def initialize
      @calls = 0
    end

    def name
      @calls += 1
      'drop'
    end

    def vip
      @calls += 1
      true
    end
  end

  def test_drop_methods_are_never_invoked_during_preprocessing
    drop = TrackingDrop.new
    source = '{{ brand.name }}|{% if brand.vip %}V{% endif %}|{{ customer.name }}'
    original = Template.parse(source)
    residual = original.specialize('brand' => drop)
    assert_equal(0, drop.calls)
    fresh_drop = TrackingDrop.new
    expected = original.render!('brand' => fresh_drop, 'customer' => { 'name' => 'x' })
    fresh_drop2 = TrackingDrop.new
    actual = residual.render!('brand' => fresh_drop2, 'customer' => { 'name' => 'x' })
    assert_equal(expected, actual)
  end

  class BoomTag < Liquid::Tag
    def render(_context)
      raise 'BOOM'
    end
  end

  def test_custom_tags_are_retained_and_not_executed
    env = Environment.build { |e| e.register_tag('boom', BoomTag) }
    template = Template.parse('A{% boom %}B', environment: env)
    residual = template.specialize({}, environment: env)
    assert(residual.root.nodes.any? { |node| node.is_a?(BoomTag) })
    assert_raises(RuntimeError) { residual.render! }
  end

  def test_dynamic_render_is_not_inlined
    template = Template.parse('{{ brand.name }}{% render "snippet", name: customer.name %}')
    residual = template.specialize('brand' => BRAND)
    assert(residual.root.nodes.any? { |node| node.is_a?(Render) })
  end

  def test_unavoidable_filter_error_is_deferred_to_render
    assert_equivalent(
      '{{ brand.n | divided_by: 0 }}',
      { 'brand' => BRAND }, remainder_sets,
    )
  end

  def test_strict_variables_during_preprocessing
    template = Template.parse('{{ definitely_missing }}')
    residual = template.specialize({}, strict_variables: false)
    assert_equal('', residual.render!)

    assert_raises(UndefinedVariable) do
      Template.parse('{{ definitely_missing }}').specialize({}, strict_variables: true)
    end
  end

  def test_pure_filter_registry_is_explicit
    registry = PureFilterRegistry.new(names: %w[upcase])
    assert(registry.allow?('upcase'))
    refute(registry.allow?('downcase'))
    registry.register(:downcase)
    assert(registry.allow?('downcase'))
    registry.unregister('upcase')
    refute(registry.allow?('upcase'))
  end

  def test_environment_registers_pure_filters
    env = Environment.build { |e| e.register_pure_filter(:my_pure) }
    assert(env.pure_filters.allow?('my_pure'))
  end

  def test_unknown_loop_cap_is_not_unrolled
    big = { 'items' => (1..60).to_a }
    template = Template.parse('{% for i in items %}{{ i }}{% endfor %}')
    residual = template.specialize(big, max_unrolled_iterations: 50)
    assert(residual.root.nodes.any? { |node| node.is_a?(For) })
    assert_equal((1..60).map(&:to_s).join, residual.render!(big))
  end

  def test_class_level_preprocess
    residual = Template.preprocess('{{ brand.name }}', 'brand' => BRAND)
    assert_kind_of(Template, residual)
    assert_equal('Acme', residual.render!)
  end

  def test_whitespace_semantics_of_dropped_blank_blocks
    source = "a\n{% if false %}\n  {{ customer.name }}\n{% endif %}\nb"
    assert_equivalent(source, { 'brand' => BRAND }, remainder_sets)
    source2 = "a\n{% if brand.vip %}\n  x\n{% endif %}\nb"
    assert_equivalent(source2, { 'brand' => BRAND }, remainder_sets)
  end
end
