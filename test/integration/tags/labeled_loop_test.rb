# frozen_string_literal: true

require 'test_helper'

class LabeledLoopTest < Minitest::Test
  include Liquid

  def test_grouped_export_continues_to_next_group_after_first_valid_record
    template = <<~LIQUID
      {%- for group in groups label: by_group -%}
        {{ group.name }}:
        {%- for item in group.items -%}
          {%- if item.available -%}
            {{ item.sku }};{% continue by_group %}
          {%- endif -%}
        {%- endfor -%}
        (none)
      {%- endfor -%}
    LIQUID

    groups = [
      { 'name' => 'A', 'items' => [
        { 'sku' => 'a1', 'available' => false },
        { 'sku' => 'a2', 'available' => true },
        { 'sku' => 'a3', 'available' => true },
      ] },
      { 'name' => 'B', 'items' => [{ 'sku' => 'b1', 'available' => false }] },
      { 'name' => 'C', 'items' => [{ 'sku' => 'c1', 'available' => true }] },
    ]

    assert_template_result('A:a2;B:(none)C:c1;', template, { 'groups' => groups })
  end

  def test_break_to_outer_label_from_nested_loop
    template = <<~LIQUID
      {%- for i in (1..3) label: outer -%}
        {%- for j in (1..3) -%}
          {%- if j == 2 -%}{% break outer %}{%- endif -%}
          {{ i }}{{ j }}
        {%- endfor -%}
      {%- endfor -%}
      done
    LIQUID

    assert_template_result("11done\n", template)
  end

  def test_three_level_loop_continue_to_outermost_keeps_rendering
    template = <<~LIQUID
      {%- for i in (1..3) label: outer -%}
        {%- for j in (1..3) label: middle -%}
          {%- for k in (1..3) -%}
            {%- if i == 2 and j == 2 and k == 2 -%}{% continue outer %}{%- endif -%}
            {{ i }}{{ j }}{{ k }}
          {%- endfor -%}
        {%- endfor -%}
        |done{{ i }}
      {%- endfor -%}
    LIQUID

    expected = '111112113121122123131132133|done1' \
               '211212213221' \
               '311312313321322323331332333|done3'

    assert_template_result(expected, template)
  end

  def test_continue_to_middle_label_from_innermost_loop
    template = <<~LIQUID
      {%- for i in (1..2) -%}
        {%- for j in (1..3) label: mid -%}
          {%- for k in (1..5) -%}
            {%- if k == 2 -%}{% continue mid %}{%- endif -%}
            {{ i }}{{ j }}{{ k }}
          {%- endfor -%}
          x
        {%- endfor -%}
      {%- endfor -%}
    LIQUID

    assert_template_result('111121131211221231', template)
  end

  def test_unlabeled_break_and_continue_still_target_innermost_loop
    template = <<~LIQUID
      {%- for i in (1..3) label: outer -%}
        {%- for j in (1..4) -%}
          {%- if j == 2 -%}{% continue %}{%- endif -%}
          {%- if j == 4 -%}{% break %}{%- endif -%}
          {{ i }}{{ j }}
        {%- endfor -%}
      {%- endfor -%}
    LIQUID

    assert_template_result('111321233133', template)
  end

  def test_parentloop_and_counters_stay_correct_when_breaking_multiple_levels
    template = <<~LIQUID
      {%- for i in (1..3) label: outer -%}
        {%- for j in (1..3) -%}
          p{{ forloop.parentloop.index }}.{{ forloop.index }}
          {%- if j == 2 -%}{% break outer %}{%- endif -%}
        {%- endfor -%}
      {%- endfor -%}
      ;after
    LIQUID

    assert_template_result("p1.1p1.2;after\n", template)
  end

  def test_inner_counters_restart_after_continue_to_outer_label
    template = <<~LIQUID
      {%- for i in (1..3) label: outer -%}
        {%- for j in (1..4) -%}
          {%- if j == 3 -%}{% continue outer %}{%- endif -%}
          {{ forloop.parentloop.index }}.{{ forloop.index }}
        {%- endfor -%}
      {%- endfor -%}
    LIQUID

    assert_template_result('1.11.22.12.23.13.2', template)
  end

  def test_offset_continue_values_after_labeled_break
    template = '{% for i in (1..6) label: o offset:continue limit:2 %}' \
               '{{ i }}{% for j in (1..2) %}{% break o %}{% endfor %}' \
               '{% endfor %}' \
               '|{% for i in (1..6) offset:continue limit:2 %}{{ i }}{% endfor %}'

    assert_template_result('1|34', template)
  end

  def test_sibling_loops_may_reuse_a_label
    template = '{% for i in (1..2) label: x %}{{ i }}{% break x %}{% endfor %}' \
               '{% for i in (3..4) label: x %}{{ i }}{% break x %}{% endfor %}'

    assert_template_result('13', template)
  end

  def test_break_with_undefined_label_raises_clear_error
    assert_match_syntax_error(
      "Syntax Error in 'break' - No enclosing for loop declares the label 'nope'",
      '{% for i in (1..3) label: outer %}{% break nope %}{% endfor %}',
    )
  end

  def test_continue_with_undefined_label_raises_clear_error
    assert_match_syntax_error(
      "Syntax Error in 'continue' - No enclosing for loop declares the label 'nope'",
      '{% for i in (1..3) label: outer %}{% continue nope %}{% endfor %}',
    )
  end

  def test_shadowing_an_enclosing_label_raises_clear_error
    assert_match_syntax_error(
      "Syntax Error in 'for loop' - Label 'x' is already declared by an enclosing for loop",
      '{% for i in (1..3) label: x %}{% for j in (1..3) label: x %}{% endfor %}{% endfor %}',
    )
  end

  def test_invalid_break_markup_raises_clear_error
    assert_match_syntax_error(
      "Syntax Error in 'break' - Valid syntax: break [label]",
      '{% for i in (1..3) label: x %}{% break x y %}{% endfor %}',
    )
  end

  def test_invalid_for_label_raises_clear_error
    assert_match_syntax_error(
      "Syntax Error in 'for loop' - Invalid label '1bad'",
      '{% for i in (1..3) label: 1bad %}{% endfor %}',
      error_mode: :lax,
    )
  end

  def test_invalid_for_label_in_strict_mode_raises_clear_error
    assert_match_syntax_error(
      'Expected id but found number',
      '{% for i in (1..3) label: 1bad %}{% endfor %}',
      error_mode: :strict,
    )
  end

  def test_labeled_break_cannot_cross_render_boundary
    file_system = StubFileSystem.new('snippet' => '{% break outer %}')
    environment = Liquid::Environment.build(file_system: file_system)
    template    = Liquid::Template.parse(
      '{% for i in (1..3) label: outer %}{% render "snippet" %}{% endfor %}',
      environment: environment,
    )
    registers = Liquid::Registers.new(file_system: file_system)
    context   = Liquid::Context.build(
      static_environments: {}, rethrow_errors: true, registers: registers, environment: environment
    )

    exception = assert_raises(Liquid::SyntaxError) { template.render(context) }
    assert_match("No enclosing for loop declares the label 'outer'", exception.message)
  end

  def test_render_partial_may_declare_its_own_label_with_same_name
    assert_template_result(
      '11',
      '{% for i in (1..3) label: outer %}{{ i }}{% render "snippet" %}{% break outer %}{% endfor %}',
      partials: { 'snippet' => '{% for x in (1..3) label: outer %}{% if x == 2 %}{% break outer %}{% endif %}{{ x }}{% endfor %}' },
    )
  end

  def test_labeled_break_inside_tablerow_unwinds_to_enclosing_for
    template = '{% for i in (1..3) label: outer %}' \
               '{% tablerow x in (1..2) cols:2 %}{% break outer %}{% endtablerow %}' \
               '{{ i }}{% endfor %}'

    assert_template_result("<tr class=\"row1\">\n<td class=\"col1\"></td></tr>\n", template)
  end

  def test_labeled_loops_work_in_strict2_mode
    assert_template_result(
      '112131',
      '{% for i in (1..3) label: outer %}{% for j in (1..3) %}{% if j == 2 %}{% continue outer %}{% endif %}{{ i }}{{ j }}{% endfor %}{% endfor %}',
      error_mode: :strict2,
    )
  end

  def test_labeled_break_in_liquid_tag
    template = <<~LIQUID
      {%- liquid
        for i in (1..3) label: outer
          for j in (1..3)
            if j == 2
              break outer
            endif
            echo i
          endfor
        endfor
      -%}
      done
    LIQUID

    assert_template_result("1done\n", template)
  end
end
