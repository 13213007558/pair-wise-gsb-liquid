# frozen_string_literal: true

require 'test_helper'

class ForStreamingTest < Minitest::Test
  include Liquid

  # A collection that can only be enumerated once and counts how many items
  # were pulled from it, to prove the streaming loop consumes the source
  # lazily and never replays or fully buffers it.
  class SingleReadStream
    attr_reader :enumerations, :pulled

    def initialize(items)
      @items        = items
      @enumerations = 0
      @pulled       = 0
    end

    def each
      @enumerations += 1
      raise "stream was already consumed" if @enumerations > 1

      @items.each do |item|
        @pulled += 1
        yield item
      end
    end

    def to_liquid
      self
    end
  end

  # An Enumerator that raises when its fiber is run a second time and counts
  # pulled items. Enumerator#each returns the enumerator itself, so its
  # position is preserved between loops, which is what makes pause/resume
  # work on a single-read stream.
  def counted_enumerator(items)
    stats = { enumerations: 0, pulled: 0 }
    enumerator = Enumerator.new do |yielder|
      stats[:enumerations] += 1
      raise "stream was already consumed" if stats[:enumerations] > 1

      items.each do |item|
        stats[:pulled] += 1
        yielder << item
      end
    end
    [enumerator, stats]
  end

  def streaming_environment
    Liquid::Environment.build { |env| env.streaming_for_loop = true }
  end

  def assert_streaming_template_result(expected, template, assigns = {})
    environment = streaming_environment
    template = Liquid::Template.parse(template, line_numbers: true, environment: environment)
    context = Liquid::Context.build(static_environments: assigns, environment: environment)
    assert_equal(expected, template.render(context))
  end

  def render_streaming!(template, assigns = {})
    Liquid::Template.parse(template, line_numbers: true, environment: streaming_environment).render!(assigns)
  end

  def test_streaming_consumes_collection_lazily
    stream = SingleReadStream.new([1, 2, 3, 4, 5])

    assert_streaming_template_result('12345', '{% for i in stream %}{{ i }}{% endfor %}', { 'stream' => stream })
    assert_equal(1, stream.enumerations)
    assert_equal(5, stream.pulled)
  end

  def test_streaming_limit_does_not_buffer_whole_collection
    stream = SingleReadStream.new((1..10).to_a)

    assert_streaming_template_result('123', '{% for i in stream limit: 3 %}{{ i }}{% endfor %}', { 'stream' => stream })
    assert_equal(1, stream.enumerations)
    assert_equal(3, stream.pulled)
  end

  def test_streaming_infinite_stream_terminates_with_limit
    stream = Enumerator.new do |yielder|
      number = 0
      loop { yielder << (number += 1) }
    end

    # Would never terminate if the loop buffered the collection first.
    assert_streaming_template_result('123', '{% for i in stream limit: 3 %}{{ i }}{% endfor %}', { 'stream' => stream })
  end

  def test_streaming_limit_and_offset
    stream, stats = counted_enumerator((1..10).to_a)
    assert_streaming_template_result('12', '{% for i in stream limit: 2 %}{{ i }}{% endfor %}', { 'stream' => stream })
    assert_equal(2, stats[:pulled])

    stream, stats = counted_enumerator((1..10).to_a)
    assert_streaming_template_result('3456', '{% for i in stream limit: 4 offset: 2 %}{{ i }}{% endfor %}', { 'stream' => stream })
    assert_equal(6, stats[:pulled])

    stream, stats = counted_enumerator((1..10).to_a)
    assert_streaming_template_result('8910', '{% for i in stream offset: 7 %}{{ i }}{% endfor %}', { 'stream' => stream })
    assert_equal(10, stats[:pulled])
  end

  def test_streaming_offset_beyond_end_renders_else
    stream, stats = counted_enumerator([1, 2, 3])

    assert_streaming_template_result('empty', '{% for i in stream offset: 10 %}{{ i }}{% else %}empty{% endfor %}', { 'stream' => stream })
    assert_equal(3, stats[:pulled])
  end

  def test_streaming_zero_limit_renders_else_without_consuming
    stream, stats = counted_enumerator([1, 2, 3])

    assert_streaming_template_result('empty', '{% for i in stream limit: 0 %}{{ i }}{% else %}empty{% endfor %}', { 'stream' => stream })
    assert_equal(0, stats[:pulled])
  end

  def test_streaming_pause_resume_with_offset_continue
    stream, stats = counted_enumerator((1..9).to_a)
    markup = '{%for i in stream limit: 3%}{{i}}{%endfor%}' \
      ' next ' \
      '{%for i in stream offset:continue limit: 3%}{{i}}{%endfor%}' \
      ' next ' \
      '{%for i in stream offset:continue limit: 3%}{{i}}{%endfor%}'

    assert_streaming_template_result('123 next 456 next 789', markup, { 'stream' => stream })
    assert_equal(1, stats[:enumerations])
    assert_equal(9, stats[:pulled])
  end

  def test_streaming_pause_resume_after_explicit_offset
    stream, = counted_enumerator((1..10).to_a)
    markup = '{%for i in stream offset: 2 limit: 2%}{{i}}{%endfor%}' \
      '|' \
      '{%for i in stream offset:continue%}{{i}}{%endfor%}'

    assert_streaming_template_result('34|5678910', markup, { 'stream' => stream })
  end

  def test_streaming_break_continues_after_consumed_items
    stream, stats = counted_enumerator((1..10).to_a)
    markup = '{% for i in stream %}{% if i == 3 %}{% break %}{% endif %}{{ i }}{% endfor %}' \
      '|' \
      '{% for i in stream offset:continue %}{{ i }}{% endfor %}'

    # The loop looks ahead one item to know whether the current item is the
    # last, so item 4 is consumed from the single-read stream when the loop
    # breaks on item 3, and the continued loop resumes at item 5.
    assert_streaming_template_result('12|5678910', markup, { 'stream' => stream })
    assert_equal(1, stats[:enumerations])
    assert_equal(10, stats[:pulled])
  end

  def test_streaming_break_does_not_drain_stream
    stream, stats = counted_enumerator((1..10).to_a)

    assert_streaming_template_result('1', '{% for i in stream %}{{ i }}{% break %}{% endfor %}', { 'stream' => stream })
    assert_equal(2, stats[:pulled]) # one rendered item plus one lookahead
  end

  def test_streaming_continue
    stream, = counted_enumerator([1, 2, 3, 4, 5])

    assert_streaming_template_result('1245', '{% for i in stream %}{% if i == 3 %}{% continue %}{% endif %}{{ i }}{% endfor %}', { 'stream' => stream })
  end

  def test_streaming_nested_loops
    inner1, = counted_enumerator([1, 2])
    inner2, = counted_enumerator([3, 4])
    outer, = counted_enumerator([inner1, inner2])
    markup = '{% for inner in outer %}{% for i in inner %}{{ i }}{% endfor %}{% endfor %}'

    assert_streaming_template_result('1234', markup, { 'outer' => outer })
  end

  def test_streaming_nested_break_only_breaks_inner_loop
    inners = [[1, 2], [3, 4], [5, 6]].map { |items| counted_enumerator(items).first }
    outer, = counted_enumerator(inners)
    markup = '{% for inner in outer %}' \
      '{% for i in inner %}' \
      '{% if i == 1 %}{% break %}{% endif %}' \
      '{{ i }}' \
      '{% endfor %}' \
      '{% endfor %}'

    assert_streaming_template_result('3456', markup, { 'outer' => outer })
  end

  def test_streaming_parentloop
    inner1, = counted_enumerator([1, 2])
    inner2, = counted_enumerator([3, 4])
    outer, = counted_enumerator([inner1, inner2])
    markup = '{% for inner in outer %}{% for i in inner %}{{ forloop.parentloop.index }}:{{ i }} {% endfor %}{% endfor %}'

    assert_streaming_template_result('1:1 1:2 2:3 2:4 ', markup, { 'outer' => outer })
  end

  def test_streaming_empty_stream_renders_else
    stream, stats = counted_enumerator([])

    assert_streaming_template_result('empty', '{% for i in stream %}{{ i }}{% else %}empty{% endfor %}', { 'stream' => stream })
    assert_equal(0, stats[:pulled])
  end

  def test_streaming_fully_consumed_stream_renders_else_in_next_loop
    stream, stats = counted_enumerator([1, 2])
    markup = '{% for i in stream %}{{ i }}{% endfor %}' \
      '|' \
      '{% for i in stream offset:continue %}{{ i }}{% else %}done{% endfor %}'

    assert_streaming_template_result('12|done', markup, { 'stream' => stream })
    assert_equal(1, stats[:enumerations])
    assert_equal(2, stats[:pulled])
  end

  def test_streaming_forloop_helpers
    stream, = counted_enumerator([1, 2, 3])
    markup = '{% for i in stream %}{{ forloop.index }}:{{ forloop.index0 }}:{{ forloop.first }}:{{ forloop.last }};{% endfor %}'

    assert_streaming_template_result('1:0:true:false;2:1:false:false;3:2:false:true;', markup, { 'stream' => stream })
  end

  def test_streaming_forloop_last_with_limit
    stream, stats = counted_enumerator((1..10).to_a)
    markup = '{% for i in stream limit: 2 %}{{ forloop.last }} {% endfor %}'

    assert_streaming_template_result('false true ', markup, { 'stream' => stream })
    assert_equal(2, stats[:pulled])
  end

  def test_streaming_forloop_length_raises
    stream, stats = counted_enumerator([1, 2, 3])

    error = assert_raises(Liquid::ArgumentError) do
      render_streaming!('{% for i in stream %}{{ forloop.length }}{% endfor %}', { 'stream' => stream })
    end
    assert_match(/forloop\.length is not supported/, error.message)
    assert_equal(2, stats[:pulled]) # current item plus one lookahead, never drained
  end

  def test_streaming_forloop_rindex_raises
    stream, = counted_enumerator([1, 2, 3])

    error = assert_raises(Liquid::ArgumentError) do
      render_streaming!('{% for i in stream %}{{ forloop.rindex }}{% endfor %}', { 'stream' => stream })
    end
    assert_match(/forloop\.rindex is not supported/, error.message)
  end

  def test_streaming_forloop_rindex0_raises
    stream, = counted_enumerator([1, 2, 3])

    error = assert_raises(Liquid::ArgumentError) do
      render_streaming!('{% for i in stream %}{{ forloop.rindex0 }}{% endfor %}', { 'stream' => stream })
    end
    assert_match(/forloop\.rindex0 is not supported/, error.message)
  end

  def test_streaming_reversed_raises_without_consuming
    stream, stats = counted_enumerator([1, 2, 3])

    error = assert_raises(Liquid::ArgumentError) do
      render_streaming!('{% for i in stream reversed %}{{ i }}{% endfor %}', { 'stream' => stream })
    end
    assert_match(/reversed is not supported/, error.message)
    assert_equal(0, stats[:pulled])
  end

  def test_streaming_mode_keeps_array_behavior
    assigns = { 'array' => [1, 2, 3] }
    assert_streaming_template_result(' 1/3  2/3  3/3 ', '{%for item in array%} {{forloop.index}}/{{forloop.length}} {%endfor%}', assigns)
    assert_streaming_template_result(' 3  2  1 ', '{%for item in array%} {{forloop.rindex}} {%endfor%}', assigns)
    assert_streaming_template_result(' 2  1  0 ', '{%for item in array%} {{forloop.rindex0}} {%endfor%}', assigns)
    assert_streaming_template_result(' false  false  true ', '{%for item in array%} {{forloop.last}} {%endfor%}', assigns)
    assert_streaming_template_result('321', '{%for item in array reversed %}{{item}}{%endfor%}', assigns)
    assert_streaming_template_result('-', '{%for item in array%}+{%else%}-{%endfor%}', { 'array' => [] })
  end

  def test_streaming_mode_keeps_array_pause_resume
    assigns = { 'array' => [1, 2, 3, 4, 5, 6, 7, 8, 9, 0] }
    markup = '{%for i in array limit: 3%}{{i}}{%endfor%}' \
      ' next ' \
      '{%for i in array offset:continue limit: 3%}{{i}}{%endfor%}' \
      ' next ' \
      '{%for i in array offset:continue limit: 3%}{{i}}{%endfor%}'

    assert_streaming_template_result('123 next 456 next 789', markup, assigns)
  end

  def test_streaming_mode_keeps_range_and_hash_behavior
    assert_streaming_template_result(' 1/3  2/3  3/3 ', '{%for item in (1..3)%} {{forloop.index}}/{{forloop.length}} {%endfor%}')
    assert_streaming_template_result('12', '{%for pair in hash%}{{ pair[0] }}{%endfor%}', { 'hash' => { '1' => 'a', '2' => 'b' } })
  end

  def test_default_mode_still_buffers_collections
    stream, stats = counted_enumerator([1, 2, 3])

    # Without the opt-in, enumerators are fully buffered so forloop.length
    # and reversed keep working.
    assert_template_result(' 1/3  2/3  3/3 ', '{%for i in stream%} {{forloop.index}}/{{forloop.length}} {%endfor%}', { 'stream' => stream })
    assert_equal(3, stats[:pulled])

    stream, = counted_enumerator([1, 2, 3])
    assert_template_result('321', '{%for i in stream reversed%}{{i}}{%endfor%}', { 'stream' => stream })
  end
end
