# frozen_string_literal: true

require 'test_helper'

class ProvenanceTest < Minitest::Test
  module ReverseFilter
    def reverse(input)
      input.to_s.reverse
    end
  end

  class StubFileSystem
    def initialize(values)
      @values = values
    end

    def read_template_file(template_path)
      @values.fetch(template_path)
    end
  end

  def parse(source, partials: {})
    environment = Liquid::Environment.build(file_system: StubFileSystem.new(partials))
    Liquid::Template.parse(source, line_numbers: true, environment: environment)
  end

  def render_with_provenance(source, assigns = {}, partials = {})
    parse(source, partials: partials).render_with_provenance(assigns)
  end

  def test_normal_render_still_returns_a_plain_string
    template = parse("{% assign a = 'x' %}{{ a | upcase }}")
    output = template.render

    assert_instance_of(String, output)
    assert_equal("X", output)
    # no provenance wrappers leak into assigns on a normal render
    assert_instance_of(String, template.instance_assigns['a'])
  end

  def test_render_with_provenance_returns_output_and_map
    result = render_with_provenance("Hello {{ name }}!", 'name' => 'bob')

    assert_equal("Hello bob!", result.output)
    assert_kind_of(Liquid::Provenance::Map, result.provenance)
  end

  def test_basic_variable_span_points_at_variable_and_template_position
    template = parse("Hello {{ name }}!")
    template.name = 'greeting'
    result = template.render_with_provenance('name' => 'bob')

    spans = result.provenance.query(6...9)
    assert_equal(1, spans.length)
    span = spans.first
    assert_equal(6...9, span.range)
    assert(span.exact?)
    assert_equal([], span.filters)
    assert_equal(1, span.sources.length)
    source = span.sources.first
    assert_equal('name', source.variable)
    assert_equal('greeting', source.template_name)
    assert_equal(1, source.line_number)
    assert_equal(0...3, source.input_range)
  end

  def test_interleaved_trimming_concatenation_and_case_conversion
    result = render_with_provenance("{{ name | strip | upcase | append: '!' | truncate: 4 }}", 'name' => '  bob  ')

    assert_equal("BOB!", result.output)

    kept = result.provenance.query(0...3)
    assert_equal(1, kept.length)
    assert(kept.first.exact?)
    assert_equal(%w[strip upcase append truncate], kept.first.filters)
    # "bob" sits at bytes 2...5 of the original value
    assert_equal('name', kept.first.sources.first.variable)
    assert_equal(2...5, kept.first.sources.first.input_range)

    bang = result.provenance.query(3...4)
    assert_equal(1, bang.length)
    assert_equal('!'.inspect, bang.first.sources.first.variable)
  end

  def test_slice_and_prepend_track_exact_ranges
    result = render_with_provenance("{{ name | slice: 1, 2 | prepend: '>' }}", 'name' => 'abc')

    assert_equal(">bc", result.output)

    span = result.provenance.query(1...3).first
    assert(span.exact?)
    assert_equal(%w[slice prepend], span.filters)
    assert_equal('name', span.sources.first.variable)
    assert_equal(1...3, span.sources.first.input_range)

    prefix = result.provenance.query(0...1).first
    assert_equal('>'.inspect, prefix.sources.first.variable)
  end

  def test_same_value_output_twice_yields_two_positions
    result = render_with_provenance("{{ x }}|{{ x }}", 'x' => 'ab')

    assert_equal("ab|ab", result.output)
    spans = result.provenance.spans
    assert_equal(2, spans.length)
    assert_equal([0...2, 3...5], spans.map(&:range))
    assert_equal(%w[x x], spans.map { |span| span.sources.first.variable })
  end

  def test_loop_repetition_yields_one_position_per_iteration
    result = render_with_provenance("{% for item in items %}{{ item }};{% endfor %}", 'items' => %w[a b c])

    assert_equal("a;b;c;", result.output)
    spans = result.provenance.spans
    assert_equal([0...1, 2...3, 4...5], spans.map(&:range))
    assert(spans.all? { |span| span.sources.first.variable == 'item' })
  end

  def test_capture_then_interpolate_keeps_original_source
    result = render_with_provenance(
      "{% capture c %}{{ name | upcase }}{% endcapture %}[{{ c }}]",
      'name' => 'bob',
    )

    assert_equal("[BOB]", result.output)
    spans = result.provenance.query(1...4)
    assert_equal(1, spans.length)
    assert(spans.first.exact?)
    assert_equal(['upcase'], spans.first.filters)
    assert_equal('name', spans.first.sources.first.variable)
    assert_equal(0...3, spans.first.sources.first.input_range)
  end

  def test_capture_then_filter_at_output
    result = render_with_provenance(
      "{% capture c %}{{ name }}{% endcapture %}{{ c | append: '?' }}",
      'name' => 'bob',
    )

    assert_equal("bob?", result.output)
    name_span = result.provenance.query(0...3).first
    assert_equal('name', name_span.sources.first.variable)
    assert_equal(['append'], name_span.filters)

    mark_span = result.provenance.query(3...4).first
    assert_equal('?'.inspect, mark_span.sources.first.variable)
  end

  def test_assign_chain_preserves_source
    result = render_with_provenance(
      "{% assign a = name | upcase %}{{ a }}",
      'name' => 'bob',
    )

    assert_equal("BOB", result.output)
    span = result.provenance.query(0...3).first
    assert_equal('name', span.sources.first.variable)
    assert_equal(['upcase'], span.filters)
  end

  def test_render_tag_with_parameters_is_tracked_across_templates
    result = render_with_provenance(
      "A{% render 'snip', thing: name %}B",
      { 'name' => 'BOB' },
      { 'snip' => '<{{ thing | downcase }}>' },
    )

    assert_equal("A<bob>B", result.output)
    span = result.provenance.query(2...5).first
    assert(span.exact?)
    assert_equal(['downcase'], span.filters)
    assert_equal('thing', span.sources.first.variable)
    assert_equal('snip', span.sources.first.template_name)
    assert_equal(1, span.sources.first.line_number)
  end

  def test_render_tag_passing_a_captured_value_keeps_the_full_chain
    result = render_with_provenance(
      "{% capture c %}{{ name | upcase }}{% endcapture %}{% render 'snip', thing: c %}",
      { 'name' => 'bob' },
      { 'snip' => '{{ thing | downcase }}' },
    )

    assert_equal("bob", result.output)
    span = result.provenance.query(0...3).first
    assert_equal('name', span.sources.first.variable)
    assert_equal(%w[upcase downcase], span.filters)
  end

  def test_cross_template_range_query
    result = render_with_provenance(
      "{{ a }}{% render 'snip', c: b %}{{ b }}",
      { 'a' => '1', 'b' => '2' },
      { 'snip' => '{{ c }}' },
    )

    assert_equal("122", result.output)
    spans = result.provenance.query(0...3)
    assert_equal(['a', 'c', 'b'], spans.map { |span| span.sources.first.variable })
    assert_equal([nil, 'snip', nil], spans.map { |span| span.sources.first.template_name })
  end

  def test_undeclared_filter_marks_whole_segment_dependency
    result = render_with_provenance("{{ name | remove: 'b' }}", 'name' => 'bob')

    assert_equal("o", result.output)
    span = result.provenance.query(0...1).first
    refute(span.exact?)
    assert_equal(['remove'], span.filters)
    assert_equal('name', span.sources.first.variable)
    # no fabricated character mapping
    assert_nil(span.sources.first.input_range)
  end

  def test_filters_can_declare_exact_mappings
    Liquid::Provenance.register_filter_mapper('reverse') do |input, spans, output, _args, _raw, _site|
      next nil unless input.reverse == output

      result = []
      spans.each do |span|
        span.start.upto(span.end - 1) do |i|
          # byte i of the input lands at output.bytesize - 1 - i
          sources = span.sources.map do |source|
            if source.input_range && source.input_range.size == span.length
              shift = i - span.start
              source.with_input_range((source.input_range.begin + shift)...(source.input_range.begin + shift + 1))
            else
              source
            end
          end
          result << Liquid::Provenance::Span.new(
            output.bytesize - 1 - i,
            output.bytesize - i,
            sources,
            span.filters + ['reverse'],
            span.exact?,
          )
        end
      end
      result
    end

    tracker = Liquid::Provenance::Tracker.new
    output = parse("{{ name | reverse }}").render({ 'name' => 'abc' }, filters: [ReverseFilter], provenance: tracker)

    assert_equal("cba", output)
    map = Liquid::Provenance::Map.new(tracker.spans)
    span = map.query(0...1).first
    assert(span.exact?)
    # the first output byte comes from the last byte of the input
    assert_equal(2...3, span.sources.first.input_range)
  ensure
    Liquid::Provenance.unregister_filter_mapper('reverse')
  end

  def test_custom_filter_without_declared_mapping_is_coarse
    tracker = Liquid::Provenance::Tracker.new
    output = parse("{{ name | reverse }}").render({ 'name' => 'abc' }, filters: [ReverseFilter], provenance: tracker)

    assert_equal("cba", output)
    map = Liquid::Provenance::Map.new(tracker.spans)
    span = map.query(0...3).first
    refute(span.exact?)
    assert_equal(['reverse'], span.filters)
    assert_equal('name', span.sources.first.variable)
  end

  def test_map_does_not_store_variable_values
    secret = 's3cr3t-token'
    result = render_with_provenance("{{ token | upcase }}", 'token' => secret)

    map_dump = result.provenance.inspect + result.provenance.spans.map(&:inspect).join
    refute_includes(map_dump, secret)
    refute_includes(map_dump, secret.upcase)
  end

  def test_multibyte_case_conversion_stays_exact
    result = render_with_provenance("{{ name | upcase }}", 'name' => 'straße')

    assert_equal("STRASSE", result.output)
    span = result.provenance.query(0...7).first
    assert(span.exact?)
    assert_equal('name', span.sources.first.variable)
    assert_equal(0...7, span.sources.first.input_range)
  end

  def test_query_by_offset_and_length_and_at
    result = render_with_provenance("{{ a }}-{{ b }}", 'a' => 'x', 'b' => 'yy')

    assert_equal(['a'], result.provenance.at(0).map { |s| s.sources.first.variable })
    assert_equal(['b'], result.provenance.query(2, 2).map { |s| s.sources.first.variable })
    # the literal separator is not attributed to any variable
    assert_empty(result.provenance.at(1))
  end

  def test_echo_tag_is_tracked
    result = render_with_provenance("{% liquid\n  echo name | upcase\n%}", 'name' => 'bob')

    assert_equal("BOB", result.output)
    span = result.provenance.query(0...3).first
    assert_equal('name', span.sources.first.variable)
    assert_equal(2, span.sources.first.line_number)
    assert_equal(['upcase'], span.filters)
  end

  def test_ifchanged_reanchors_spans
    result = render_with_provenance("{% ifchanged %}{{ name }}{% endifchanged %}", 'name' => 'bob')

    assert_equal("bob", result.output)
    span = result.provenance.query(0...3).first
    assert_equal('name', span.sources.first.variable)
  end

  def test_provenance_option_can_be_passed_to_render_directly
    tracker = Liquid::Provenance::Tracker.new
    output = parse("{{ name }}").render({ 'name' => 'bob' }, provenance: tracker)

    assert_equal("bob", output)
    map = Liquid::Provenance::Map.new(tracker.spans)
    assert_equal('name', map.at(0).first.sources.first.variable)
  end

  def test_tracker_is_removed_from_registers_after_render
    template = parse("{{ name }}")
    context = Liquid::Context.new('name' => 'bob')
    template.render(context, provenance: Liquid::Provenance::Tracker.new)

    assert_nil(context.registers.static[:provenance])
  end

  def test_array_output_is_tracked_coarsely
    result = render_with_provenance("{{ items }}", 'items' => [1, 2])

    assert_equal("12", result.output)
    span = result.provenance.query(0...2).first
    assert_equal('items', span.sources.first.variable)
  end

  def test_default_filter_uses_declared_mapping
    result = render_with_provenance("{{ name | default: 'anon' }}", 'name' => 'bob')
    span = result.provenance.query(0...3).first
    assert(span.exact?)
    assert_equal('name', span.sources.first.variable)
    assert_equal(['default'], span.filters)

    # a nil input cannot be mapped byte-by-byte: whole-dependency fallback
    fallback = render_with_provenance("{{ name | default: 'anon' }}")
    span = fallback.provenance.query(0...4).first
    refute(span.exact?)
    assert_equal(['default'], span.filters)
  end
end
