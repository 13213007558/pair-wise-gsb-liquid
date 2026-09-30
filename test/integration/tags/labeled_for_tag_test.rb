# frozen_string_literal: true

require 'test_helper'

class LabeledForTagTest < Minitest::Test
  include Liquid

  def test_labeled_continue_skips_to_next_group
    # Grouped export: once a valid record is found in a group, move on to
    # the next group without a boolean flag.
    groups = [
      { 'name' => 'g1', 'items' => [{ 'name' => 'a', 'valid' => false }, { 'name' => 'b', 'valid' => true }, { 'name' => 'c', 'valid' => true }] },
      { 'name' => 'g2', 'items' => [{ 'name' => 'd', 'valid' => false }, { 'name' => 'e', 'valid' => true }] },
    ]
    template =
      '{% for group in groups, label: export %}' \
      '{% for item in group.items %}' \
      '{% if item.valid %}{{ group.name }}={{ item.name }};{% continue export %}{% endif %}' \
      '{% endfor %}' \
      '{% endfor %}'

    assert_template_result('g1=b;g2=e;', template, { 'groups' => groups })
  end

  def test_labeled_continue_in_three_nested_loops_keeps_rendering
    template =
      '{% for a in (1..3), label: outer %}' \
      'A{{ forloop.index }}:' \
      '{% for b in (1..2), label: middle %}' \
      'B{{ forloop.index }}:' \
      '{% for c in (1..3) %}' \
      '{% if c == 2 %}{% continue outer %}{% endif %}' \
      'C{{ forloop.index }};' \
      '{% endfor %}' \
      '{% endfor %}' \
      '|' \
      '{% endfor %}' \
      'done'

    # jumping to the outer continue skips the rest of the middle and inner
    # loops, then the outer loop keeps iterating and rendering continues
    assert_template_result('A1:B1:C1;A2:B1:C1;A3:B1:C1;done', template)
  end

  def test_labeled_break_exits_multiple_loops
    template =
      '{% for group in groups, label: export %}' \
      '[' \
      '{% for item in group %}' \
      '{% if item == 2 %}{% break export %}{% endif %}' \
      '{{ item }}' \
      '{% endfor %}' \
      ']' \
      '{% endfor %}' \
      '!'

    assert_template_result('[1!', template, { 'groups' => [[1, 2, 3], [4, 5]] })
  end

  def test_unlabeled_break_and_continue_still_target_innermost_loop
    template =
      '{% for a in (1..2), label: outer %}' \
      '{% for b in (1..3) %}' \
      '{% if b == 2 %}{% break %}{% endif %}' \
      '{{ a }}{{ b }};' \
      '{% endfor %}' \
      '.' \
      '{% endfor %}'

    assert_template_result('11;.21;.', template)

    template =
      '{% for a in (1..2), label: outer %}' \
      '{% for b in (1..3) %}' \
      '{% if b == 2 %}{% continue %}{% endif %}' \
      '{{ a }}{{ b }};' \
      '{% endfor %}' \
      '{% endfor %}'

    assert_template_result('11;13;21;23;', template)
  end

  def test_forloop_parentloop_and_counters_after_multi_level_jump
    template =
      '{% for a in (1..3), label: outer %}' \
      '{% for b in (1..3) %}' \
      '{% if b == 2 %}{% continue outer %}{% endif %}' \
      'a{{ forloop.parentloop.index }}b{{ forloop.index }};' \
      '{% endfor %}' \
      '{% endfor %}'

    # the outer counter keeps incrementing and the inner counter restarts
    assert_template_result('a1b1;a2b1;a3b1;', template)

    template =
      '{% for a in (1..3), label: outer %}' \
      '{% for b in (1..3) %}' \
      '{% if b == 2 %}{% break outer %}{% endif %}' \
      'a{{ forloop.parentloop.index }}b{{ forloop.index }};' \
      '{% endfor %}' \
      '{% endfor %}'

    assert_template_result('a1b1;', template)
  end

  def test_offset_continue_after_labeled_break
    template =
      '{% for i in (1..6), label: nums, limit: 2 %}' \
      '{{ i }}' \
      '{% break nums %}' \
      '{% endfor %}' \
      '|' \
      '{% for i in (1..6), offset: continue, limit: 2 %}' \
      '{{ i }}' \
      '{% endfor %}'

    assert_template_result('1|34', template)
  end

  def test_sibling_loops_may_reuse_a_label
    template =
      '{% for a in (1..2), label: each %}{{ a }}{% endfor %}' \
      '{% for b in (1..2), label: each %}{{ b }}{% break each %}{% endfor %}'

    assert_template_result('121', template)
  end

  def test_labeled_interrupt_propagates_through_tablerow
    template =
      '{% for a in (1..3), label: outer %}' \
      '{% tablerow b in (1..3) %}' \
      '{% if b == 2 %}{% break outer %}{% endif %}' \
      '{{ b }}' \
      '{% endtablerow %}' \
      'X' \
      '{% endfor %}' \
      '!'

    assert_template_result(
      "<tr class=\"row1\">\n<td class=\"col1\">1</td><td class=\"col2\"></td></tr>\n!",
      template,
    )
  end

  def test_labeled_loop_with_strict_parser
    assert_template_result(
      '1',
      '{% for a in (1..3), label: strict, limit: 2 %}{{ a }}{% break strict %}{% endfor %}',
      error_mode: :strict,
    )
    assert_template_result(
      '12',
      '{% for a in (1..3), label: strict, limit: 2 %}{{ a }}{% continue strict %}{% endfor %}',
      error_mode: :strict2,
    )
  end

  def test_undefined_break_label_raises
    assert_match_syntax_error(
      /No enclosing for loop is labeled 'nope'/,
      '{% for i in (1..3) %}{% break nope %}{% endfor %}',
    )
  end

  def test_undefined_continue_label_raises
    assert_match_syntax_error(
      /No enclosing for loop is labeled 'nope'/,
      '{% for i in (1..3), label: yep %}{% continue nope %}{% endfor %}',
    )
  end

  def test_duplicate_label_in_nested_loop_raises
    assert_match_syntax_error(
      /Loop label 'dup' is already declared by an enclosing for loop/,
      '{% for a in (1..3), label: dup %}{% for b in (1..3), label: dup %}{% endfor %}{% endfor %}',
    )
  end

  def test_invalid_label_syntax_raises
    assert_match_syntax_error(
      /Invalid loop label '123'/,
      '{% for a in (1..3), label: 123 %}{% endfor %}',
      error_mode: :lax,
    )
    assert_match_syntax_error(
      /Expected id but found number/,
      '{% for a in (1..3), label: 123 %}{% endfor %}',
      error_mode: :strict,
    )
    assert_match_syntax_error(
      /Valid syntax: break \[label\]/,
      '{% for a in (1..3) %}{% break foo bar %}{% endfor %}',
    )
    assert_match_syntax_error(
      /Valid syntax: continue \[label\]/,
      '{% for a in (1..3) %}{% continue "x" %}{% endfor %}',
    )
  end

  def test_labeled_break_cannot_jump_across_render_partial
    file_system = StubFileSystem.new('snippet' => '{% break outer %}')
    environment = Liquid::Environment.build(file_system: file_system)
    template   = Liquid::Template.parse(
      '{% for i in (1..3), label: outer %}{% render "snippet" %}{% endfor %}',
      environment: environment,
    )

    error = assert_raises(Liquid::SyntaxError) do
      template.render!(registers: { file_system: file_system })
    end
    assert_match(/No enclosing for loop is labeled 'outer'/, error.message)
  end

  def test_label_declared_inside_partial_is_usable_there
    file_system = StubFileSystem.new(
      'snippet' => '{% for x in (1..3), label: inner %}{{ x }}{% break inner %}{% endfor %}',
    )
    environment = Liquid::Environment.build(file_system: file_system)
    template   = Liquid::Template.parse('{% render "snippet" %}', environment: environment)

    assert_equal('1', template.render!(registers: { file_system: file_system }))
  end
end
