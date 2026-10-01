# frozen_string_literal: true

require 'test_helper'

class StreamTagTest < Minitest::Test
  include Liquid

  # A one-shot, size-less, non-rewindable collection that raises if it is
  # read further than the stated allowance.
  class GuardedStream
    def initialize(values, max_reads: values.size)
      @values = values
      @max_reads = max_reads
      @reads = 0
    end

    attr_reader :reads

    def to_liquid
      self
    end

    def each
      return enum_for(:each) unless block_given?

      @values.each do |value|
        @reads += 1
        raise "read past the allowed #{@max_reads} items" if @reads > @max_reads

        yield value
      end
    end
  end

  def test_stream_iterates_any_enumerable
    assert_template_result('123', '{% stream x in items %}{{ x }}{% endstream %}', { 'items' => [1, 2, 3] })
    assert_template_result('abc', '{% stream x in items %}{{ x }}{% endstream %}', { 'items' => 'abc'.chars })
  end

  def test_stream_consumes_one_shot_enumerator_lazily
    enumerator = Enumerator.new { |y| 3.times { |i| y << i } }
    assert_template_result('012', '{% stream x in items %}{{ x }}{% endstream %}', { 'items' => enumerator })
  end

  def test_stream_break_does_not_over_read
    # Output the first three items, then break. The lookahead for
    # `forloop.last` may pull the fourth item, but never the fifth.
    stream = GuardedStream.new((1..10).to_a, max_reads: 4)
    template = '{% stream x in items %}{{ x }}{% if forloop.index == 3 %}{% break %}{% endif %}{% endstream %}'
    assert_template_result('123', template, { 'items' => stream })
    assert_operator(stream.reads, :<=, 4)
  end

  def test_stream_forloop_last_uses_single_item_lookahead
    stream = GuardedStream.new(%w[a b c])
    template = '{% stream x in items %}{{ x }}{% if forloop.last %}+{% endif %}{% endstream %}'
    assert_template_result('ab c+'.delete(' '), template, { 'items' => stream })
  end

  def test_stream_forloop_index_and_first
    template = '{% stream x in items %}[{{ forloop.index }}:{{ forloop.index0 }}:{{ forloop.first }}]{% endstream %}'
    assert_template_result('[1:0:true][2:1:false]', template, { 'items' => %w[a b] })
  end

  def test_stream_length_dependent_properties_are_unavailable
    template = '{% stream x in items %}' \
      '{{ forloop.length | default: "n/a" }}:{{ forloop.rindex | default: "n/a" }}:{{ forloop.rindex0 | default: "n/a" }};' \
      '{% endstream %}'
    assert_template_result('n/a:n/a:n/a;n/a:n/a:n/a;', template, { 'items' => %w[a b] })
  end

  def test_stream_reversed_is_rejected
    assert_match_syntax_error(
      /cannot be reversed/,
      '{% stream x in items reversed %}{{ x }}{% endstream %}',
    )
  end

  def test_stream_limit
    assert_template_result('12', '{% stream x in items limit:2 %}{{ x }}{% endstream %}', { 'items' => [1, 2, 3, 4] })
  end

  def test_stream_limit_does_not_read_past_the_cap
    stream = GuardedStream.new((1..10).to_a, max_reads: 3)
    assert_template_result('123', '{% stream x in items limit:3 %}{{ x }}{% endstream %}', { 'items' => stream })
    assert_equal(3, stream.reads)
  end

  def test_stream_offset
    assert_template_result('34', '{% stream x in items offset:2 %}{{ x }}{% endstream %}', { 'items' => [1, 2, 3, 4] })
  end

  def test_stream_offset_continue
    template = '{% stream x in items limit:2 %}{{ x }}{% endstream %}' \
      '|{% stream x in items offset:continue limit:2 %}{{ x }}{% endstream %}'
    assert_template_result('12|34', template, { 'items' => [1, 2, 3, 4, 5] })
  end

  def test_stream_offset_continue_after_break_resumes_after_last_rendered_item
    template = '{% stream x in items %}{{ x }}{% if forloop.index == 2 %}{% break %}{% endif %}{% endstream %}' \
      '|{% stream x in items offset:continue limit:2 %}{{ x }}{% endstream %}'
    assert_template_result('12|34', template, { 'items' => [1, 2, 3, 4, 5] })
  end

  def test_stream_continue
    template = '{% stream x in items %}{% if x == 2 %}{% continue %}{% endif %}{{ x }}{% endstream %}'
    assert_template_result('134', template, { 'items' => [1, 2, 3, 4] })
  end

  def test_stream_else_when_collection_is_empty
    assert_template_result('EMPTY', '{% stream x in items %}{{ x }}{% else %}EMPTY{% endstream %}', { 'items' => [] })
    assert_template_result('EMPTY', '{% stream x in items %}{{ x }}{% else %}EMPTY{% endstream %}', { 'items' => nil })
  end

  def test_stream_else_when_limit_is_zero
    assert_template_result('EMPTY', '{% stream x in items limit:0 %}{{ x }}{% else %}EMPTY{% endstream %}', { 'items' => [1] })
  end

  def test_stream_else_when_offset_passes_the_end
    assert_template_result('EMPTY', '{% stream x in items offset:10 %}{{ x }}{% else %}EMPTY{% endstream %}', { 'items' => [1, 2] })
  end

  def test_stream_string_is_a_single_item
    assert_template_result('hello', '{% stream x in items %}{{ x }}{% endstream %}', { 'items' => 'hello' })
  end

  def test_stream_nested_parentloop
    template = '{% stream a in items %}{% stream b in items %}{{ forloop.parentloop.index }}.{{ forloop.index }} {% endstream %}{% endstream %}'
    assert_template_result('1.1 1.2 2.1 2.2 ', template, { 'items' => [1, 2] })
  end
end
