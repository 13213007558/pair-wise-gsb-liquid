# frozen_string_literal: true

require 'test_helper'

class ForStreamTagTest < Minitest::Test
  include Liquid

  # A one-shot collection of records, as an export task might hand to Liquid:
  # it can only be traversed once, has no size, cannot be rewound or
  # materialized, and raises if more than +max_reads+ records are pulled.
  class GuardedRecords
    attr_reader :reads

    def initialize(records, max_reads:)
      @records   = records
      @max_reads = max_reads
      @reads     = 0
    end

    def each
      return to_enum(:each) unless block_given?

      @records.each do |record|
        @reads += 1
        raise "read beyond #{@max_reads} records" if @reads > @max_reads

        yield record
      end
    end

    def size
      raise "size must not be called in streaming mode"
    end

    def rewind
      raise "rewind must not be called in streaming mode"
    end

    def to_a
      raise "to_a must not be called in streaming mode"
    end

    def to_liquid
      self
    end
  end

  # A genuine one-shot Enumerator that raises when read past +max_reads+ items.
  def guarded_enumerator(records, max_reads:, counter:)
    Enumerator.new do |yielder|
      records.each do |record|
        counter[:reads] += 1
        raise "read beyond #{max_reads} records" if counter[:reads] > max_reads

        yielder << record
      end
    end
  end

  def test_stream_iterates_without_buffering_sizing_or_rewinding
    records = GuardedRecords.new([1, 2, 3], max_reads: 3)

    assert_template_result(
      "123",
      "{% for item in items stream %}{{ item }}{% endfor %}",
{ "items" => records },
    )
    assert_equal(3, records.reads)
  end

  def test_stream_break_stops_consuming_the_enumerator
    counter = { reads: 0 }
    enum    = guarded_enumerator((1..100).to_a, max_reads: 4, counter: counter)

    template = "{% for item in items stream %}{{ item }}" \
      "{% if forloop.index == 3 %}{% break %}{% endif %}{% endfor %}"

    assert_template_result("123", template, { "items" => enum })

    # Rendering the third item requires one item of lookahead (for
    # `forloop.last`), but nothing past the fourth record may be read.
    assert_equal(4, counter[:reads])
  end

  def test_stream_forloop_index_first_and_last
    template = "{% for item in items stream %}" \
      "{{ forloop.index }}:{{ forloop.index0 }}:{{ forloop.first }}:{{ forloop.last }};" \
      "{% endfor %}"

    assert_template_result(
      "1:0:true:false;2:1:false:false;3:2:false:true;",
      template,
{ "items" => GuardedRecords.new([1, 2, 3], max_reads: 4) },
    )
  end

  def test_stream_length_dependent_attributes_are_unavailable
    template = "{% for item in items stream %}" \
      "[{{ forloop.length }}|{{ forloop.rindex }}|{{ forloop.rindex0 }}]" \
      "{% if forloop.length == nil %}nil{% endif %}" \
      "{% endfor %}"

    assert_template_result(
      "[||]nil[||]nil",
      template,
{ "items" => GuardedRecords.new([1, 2], max_reads: 3) },
    )
  end

  def test_stream_limit_stops_reading_at_the_limit
    counter = { reads: 0 }
    enum    = guarded_enumerator((1..100).to_a, max_reads: 2, counter: counter)

    template = "{% for item in items stream limit: 2 %}{{ item }}:{{ forloop.last }};{% endfor %}"

    assert_template_result("1:false;2:true;", template, { "items" => enum })
    assert_equal(2, counter[:reads])
  end

  def test_stream_limit_zero_renders_else_without_reading
    counter = { reads: 0 }
    enum    = guarded_enumerator([1, 2, 3], max_reads: 3, counter: counter)

    template = "{% for item in items stream limit: 0 %}{{ item }}{% else %}none{% endfor %}"

    assert_template_result("none", template, { "items" => enum })
    assert_equal(0, counter[:reads])
  end

  def test_stream_negative_limit_renders_else
    template = "{% for item in items stream limit: -1 %}{{ item }}{% else %}none{% endfor %}"

    assert_template_result("none", template, { "items" => [1, 2, 3] })
  end

  def test_stream_offset_skips_records
    assert_template_result(
      "34",
      "{% for item in items stream offset: 2 %}{{ item }}{% endfor %}",
{ "items" => [1, 2, 3, 4] },
    )
  end

  def test_stream_offset_continue
    template = "{% for item in items stream limit: 2 %}{{ item }}{% endfor %}" \
      "|{% for item in items stream offset: continue limit: 2 %}{{ item }}{% endfor %}"

    assert_template_result("12|34", template, { "items" => [1, 2, 3, 4, 5] })
  end

  def test_stream_else_renders_for_empty_collection
    template = "{% for item in items stream %}{{ item }}{% else %}empty{% endfor %}"

    assert_template_result("empty", template, { "items" => [] })
    assert_template_result("empty", template, { "items" => nil })
  end

  def test_stream_else_renders_when_offset_consumes_the_collection
    template = "{% for item in items stream offset: 5 %}{{ item }}{% else %}empty{% endfor %}"

    assert_template_result("empty", template, { "items" => [1, 2] })
  end

  def test_stream_continue_tag_skips_to_next_record
    template = "{% for item in items stream %}" \
      "{% if item == 2 %}{% continue %}{% endif %}{{ item }}" \
      "{% endfor %}"

    assert_template_result("13", template, { "items" => [1, 2, 3] })
  end

  def test_stream_works_with_ranges
    assert_template_result(
      "123",
      "{% for item in (1..3) stream %}{{ item }}{% endfor %}",
    )
  end

  def test_stream_supports_nested_loops_with_parentloop
    template = "{% for a in xs stream %}" \
      "{% for b in ys stream %}{{ a }}{{ b }}:{{ forloop.parentloop.index }};{% endfor %}" \
      "{% endfor %}"

    assert_template_result(
      "1a:1;1b:1;2a:2;2b:2;",
      template,
{ "xs" => [1, 2], "ys" => ["a", "b"] },
    )
  end

  def test_stream_reversed_is_rejected
    assert_match_syntax_error(
      "'reversed' cannot be combined with 'stream'",
      "{% for item in (1..3) reversed stream %}{% endfor %}",
    )
    assert_match_syntax_error(
      "'reversed' cannot be combined with 'stream'",
      "{% for item in (1..3) stream reversed %}{% endfor %}",
    )
  end
end
