# frozen_string_literal: true

require 'test_helper'

class SourceMapUnitTest < Minitest::Test
  def render_map(source, assigns = {}, options = {})
    template = Liquid::Template.parse(source, line_numbers: true)
    output = template.render!(assigns, { source_map: true }.merge(options))
    [output, template.source_map]
  end

  def origins_at(map, offset, length = 1)
    map.origins_at(offset, length).map(&:to_h)
  end

  def variables_at(map, offset, length = 1)
    map.origins_at(offset, length).map(&:variable)
  end

  def filters_at(map, offset, length = 1)
    map.origins_at(offset, length).map(&:filters)
  end

  # --- behaviour without the option -----------------------------------------

  def test_normal_rendering_returns_plain_string_and_no_map
    template = Liquid::Template.parse("hi {{ name }}")
    output = template.render!('name' => 'ada')

    assert_instance_of(String, output)
    refute_kind_of(Liquid::SourceMap::TracedString, output)
    assert_equal('hi ada', output)
    assert_nil(template.source_map)
  end

  def test_traced_render_also_returns_plain_string
    output, map = render_map("hi {{ name }}", 'name' => 'ada')

    assert_instance_of(String, output)
    refute_kind_of(Liquid::SourceMap::TracedString, output)
    assert_equal('hi ada', output)
    assert_kind_of(Liquid::SourceMap::SourceMap, map)
  end

  # --- basic attribution ----------------------------------------------------

  def test_variable_bytes_are_attributed
    _output, map = render_map("hi {{ name }}!", 'name' => 'ada')

    assert_equal(['name'], variables_at(map, 3, 3))
    origin = map.origins_at(3).first
    assert_equal(:variable, origin.source)
    assert_equal('name', origin.variable)
    assert_equal(1, origin.line_number)
    assert_equal('name', origin.markup)
  end

  def test_literal_template_text_is_attributed_to_template
    _output, map = render_map("hi {{ name }}!", 'name' => 'ada')

    assert_equal([:template], map.origins_at(0, 2).map(&:source))
    assert_equal([:template], map.origins_at(6, 1).map(&:source))
  end

  def test_unknown_variable_produces_no_variable_span
    _output, map = render_map("a{{ missing }}b", {})

    assert_equal('ab', _output)
    assert_equal([:template], map.origins_at(0).map(&:source))
    assert_equal([:template], map.origins_at(1).map(&:source))
  end

  # --- interleaved slicing / concatenation / case change --------------------

  def test_slice_upcase_append_prepend_chain
    source = "{{ s | slice: 1, 3 | upcase | append: tail | prepend: lead }}"
    output, map = render_map(source, 's' => 'abcdef', 'tail' => 'ZZ', 'lead' => 'L')

    assert_equal('LBCDZZ', output)
    # carried-over bytes trace to s through every filter they passed
    assert_equal(['s'], variables_at(map, 1, 3))
    assert_equal([%w[slice upcase append prepend]], filters_at(map, 1, 1))
    # appended bytes trace to the tail argument; they also ride through the
    # later prepend, so the chain records both filters
    assert_equal(['tail'], variables_at(map, 4, 2))
    assert_equal([%w[append prepend]], filters_at(map, 4, 1))
    # prepended bytes trace to the lead argument
    assert_equal(['lead'], variables_at(map, 0, 1))
    assert_equal([['prepend']], filters_at(map, 0, 1))
  end

  def test_slice_uses_character_offsets_but_byte_ranges
    source = "{{ s | slice: 1, 2 }}"
    output, map = render_map(source, 's' => 'aécd')

    assert_equal('éc', output)
    span = map.spans(0, output.bytesize).first
    assert_equal('s', span.origins.first.variable)
    assert_equal(['slice'], span.origins.first.filters)
    assert_equal(0, span.start)
    assert_equal('éc'.bytesize, span.finish)
  end

  def test_negative_slice
    _output, map = render_map("{{ s | slice: -2, 2 }}", 's' => 'abcde')

    assert_equal(['s'], variables_at(map, 0, 2))
    assert_equal([['slice']], filters_at(map, 0, 1))
  end

  # --- length-changing filters ----------------------------------------------

  def test_truncate_attributes_kept_bytes_and_literal_suffix
    output, map = render_map("{{ s | truncate: 7 }}", 's' => 'abcdefghij')

    assert_equal('abcd...', output)
    assert_equal(['s'], variables_at(map, 0, 4))
    assert_equal([['truncate']], filters_at(map, 0, 1))
    assert_equal([:literal], map.origins_at(4, 3).map(&:source))
  end

  def test_truncate_without_actual_truncation_is_identity
    output, map = render_map("{{ s | truncate: 10 }}", 's' => 'abc')

    assert_equal('abc', output)
    assert_equal(['s'], variables_at(map, 0, 3))
    assert_equal([['truncate']], filters_at(map, 0, 1))
  end

  def test_case_conversion_that_grows_bytes_falls_back_to_whole_segment
    output, map = render_map("{{ s | upcase }}", 's' => 'aß')

    assert_equal('ASS', output)
    origins = map.origins_at(0, output.bytesize)
    assert_equal(['s'], origins.map(&:variable).uniq)
    assert_equal([['upcase']], origins.map(&:filters).uniq)
  end

  # --- undeclared filters ---------------------------------------------------

  def test_undeclared_filter_marks_whole_segment_dependency
    output, map = render_map("{{ s | escape }}", 's' => '<a>')

    assert_equal('&lt;a&gt;', output)
    origins = map.origins_at(0, output.bytesize)
    assert_equal(['s'], origins.map(&:variable).uniq)
    assert_equal([['escape']], origins.map(&:filters).uniq)
  end

  def test_mixed_exact_and_undeclared_chain_keeps_full_chain
    _output, map = render_map("{{ s | upcase | escape | downcase }}", 's' => 'ab')

    assert_equal(['s'], variables_at(map, 0))
    assert_equal([%w[upcase escape downcase]], filters_at(map, 0))
  end

  # --- repetition -----------------------------------------------------------

  def test_same_value_output_twice_gives_two_separate_spans
    _output, map = render_map("{{ x }}|{{ x }}", 'x' => 'aa')

    spans = map.spans.select { |span| span.origins.any? { |o| o.variable == 'x' } }
    assert_equal([[0, 2], [3, 5]], spans.map { |s| [s.start, s.finish] })
  end

  def test_loop_repetition_is_tracked_per_iteration
    _output, map = render_map("{% for i in (1..2) %}{{ x }};{% endfor %}", 'x' => 'ab')

    spans = map.spans.select { |span| span.origins.any? { |o| o.variable == 'x' } }
    assert_equal([[0, 2], [3, 5]], spans.map { |s| [s.start, s.finish] })
  end

  def test_loop_variable_items_are_separate_spans
    _output, map = render_map("{% for it in items %}{{ it }}{% endfor %}", 'items' => %w[p q])

    spans = map.spans.select { |span| span.origins.any? { |o| o.variable == 'it' } }
    assert_equal([[0, 1], [1, 2]], spans.map { |s| [s.start, s.finish] })
  end

  # --- capture --------------------------------------------------------------

  def test_captured_output_keeps_provenance_when_reinterpolated
    output, map = render_map(
      "{% capture g %}{{ secret }}-end{% endcapture %}{{ g | upcase }}",
      'secret' => 'shh'
    )

    assert_equal('SHH-END', output)
    assert_equal(['secret'], variables_at(map, 0, 3))
    assert_equal([['upcase']], filters_at(map, 0, 1))
    assert_equal([:template], map.origins_at(3, 4).map(&:source))
  end

  # --- assign ---------------------------------------------------------------

  def test_assign_then_output_keeps_chain
    _output, map = render_map("{% assign y = s | slice: 2, 2 %}{{ y }}", 's' => 'abcde')

    assert_equal(['s'], variables_at(map, 0, 2))
    assert_equal([['slice']], filters_at(map, 0, 1))
  end

  def test_assigned_non_string_filter_result_still_acts_like_the_value
    output, = render_map(
      "{% assign n = s | size %}{% if n == 6 %}six{% else %}other{% endif %}",
      's' => 'abcdef'
    )
    assert_equal('six', output)

    output, = render_map(
      "{% assign n = s | size %}{% if n > 3 %}big{% endif %}",
      's' => 'abcdef'
    )
    assert_equal('big', output)
  end

  def test_size_output_is_attributed_as_whole_segment
    output, map = render_map("{{ s | size }}", 's' => 'abcdef')

    assert_equal('6', output)
    assert_equal(['s'], variables_at(map, 0))
    assert_equal([['size']], filters_at(map, 0))
  end

  # --- cross-template render ------------------------------------------------

  def test_render_parameter_is_tracked_into_snippet
    file_system = StubFileSystem.new('snip' => "[{{ msg }}]")
    environment = Liquid::Environment.build(file_system: file_system)
    template = Liquid::Template.parse("{% render 'snip', msg: greeting %}", environment: environment)
    output = template.render!({ 'greeting' => 'hi' }, source_map: true)
    map = template.source_map

    assert_equal('[hi]', output)
    assert_equal(['greeting'], variables_at(map, 1, 2))
    origin = map.origins_at(1).first
    assert_equal('snip', origin.template)
  end

  def test_render_for_emits_one_span_per_iteration
    file_system = StubFileSystem.new('item' => "<{{ it }}>")
    environment = Liquid::Environment.build(file_system: file_system)
    template = Liquid::Template.parse("{% render 'item' for items as it %}", environment: environment)
    template.render!({ 'items' => %w[x y] }, source_map: true)
    map = template.source_map

    spans = map.spans.select { |span| span.origins.any? { |o| o.variable == 'items' } }
    assert_equal([[1, 2], [4, 5]], spans.map { |s| [s.start, s.finish] })
  end

  # --- tag output -----------------------------------------------------------

  def test_increment_output_is_attributed_to_tag
    output, map = render_map("{% increment i %}-{% increment i %}", {})

    assert_equal('0-1', output)
    assert_equal(:tag, map.origins_at(0).first.source)
    assert_equal(:tag, map.origins_at(2).first.source)
  end

  # --- raw tag --------------------------------------------------------------

  def test_raw_content_is_template_text
    _output, map = render_map("{% raw %}{{ x }}{% endraw %}", 'x' => 'ignored')

    assert_equal([:template], map.origins_at(0, 1).map(&:source))
    assert_empty(map.spans.flat_map(&:origins).select { |o| o.variable == 'x' })
  end

  # --- security -------------------------------------------------------------

  def test_source_map_does_not_store_variable_values
    _output, map = render_map("{{ secret }}", 'secret' => 'TOPSECRET')

    dump = Marshal.dump(map.to_a)
    refute(dump.include?('TOPSECRET'))
    map.spans.each do |span|
      span.origins.each { |origin| refute(origin.to_h.key?(:value)) }
    end
  end

  def test_map_is_enumerable_and_serializable
    _output, map = render_map("a{{ x }}", 'x' => 'b')

    hashes = map.to_a
    assert_kind_of(Array, hashes)
    assert_equal(:start, hashes.first.keys.first)
  end

  # --- custom filter mapping registration ----------------------------------

  module SameLayoutSliceFilter
    def my_slice(input, offset, length)
      input.slice(offset, length)
    end
  end

  def test_custom_filter_can_declare_exact_mapping
    environment = Liquid::Environment.build do |env|
      env.register_filter(SameLayoutSliceFilter)
    end
    Liquid::SourceMap.register_exact_filter('my_slice', :slice)

    template = Liquid::Template.parse("{{ x | my_slice: 1, 2 }}", environment: environment)
    output = template.render!({ 'x' => 'abcde' }, source_map: true)
    assert_equal('bc', output)
    origin = template.source_map.origins_at(0).first
    assert_equal('x', origin.variable)
    assert_equal(['my_slice'], origin.filters)
  end

  def test_registering_unknown_mapping_kind_raises
    assert_raises(ArgumentError) do
      Liquid::SourceMap.register_exact_filter('nope', :fabricated)
    end
  end
end
