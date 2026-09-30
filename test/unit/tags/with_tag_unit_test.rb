# frozen_string_literal: true

require 'test_helper'

class WithTagUnitTest < Minitest::Test
  include Liquid

  # --- Basic binding ---------------------------------------------------------

  def test_binds_a_single_variable
    assert_template_result(
      "42",
      "{% with x = value %}{{ x }}{% endwith %}",
      { 'value' => 42 },
    )
  end

  def test_binding_is_scoped_to_the_block
    assert_template_result(
      "inside|outer",
      "{% with x = 'inside' %}{{ x }}|{% endwith %}{{ x }}",
      { 'x' => 'outer' },
    )
  end

  def test_undefined_outer_variable_is_restored_after_the_block
    assert_template_result(
      "inside|",
      "{% with x = 'inside' %}{{ x }}|{% endwith %}{{ x }}",
    )
  end

  def test_binding_shadows_the_outer_variable_inside_the_block
    assert_template_result(
      "inner",
      "{% with x = 'inner' %}{{ x }}{% endwith %}",
      { 'x' => 'outer' },
    )
  end

  def test_outer_variable_is_restored_after_each_loop_iteration
    assert_template_result(
      "Ada:none Bob:admin ",
      "{% for u in users %}{% with [name, role = 'none'] = u %}{{ name }}:{{ role }} {% endwith %}{% endfor %}",
      { 'users' => [['Ada'], ['Bob', 'admin']] },
    )
  end

  def test_binding_can_shadow_an_assign_without_mutating_it
    assert_template_result(
      "inner|outer",
      "{% assign x = 'outer' %}{% with x = 'inner' %}{{ x }}|{% endwith %}{{ x }}",
    )
  end

  # --- Array destructuring ---------------------------------------------------

  def test_destructures_an_array_by_position
    assert_template_result(
      "Ada|read",
      "{% with [user, perm] = payload %}{{ user }}|{{ perm }}{% endwith %}",
      { 'payload' => %w[Ada read] },
    )
  end

  def test_nested_array_destructuring
    assert_template_result(
      "1-2-3",
      "{% with [a, [b, c]] = value %}{{ a }}-{{ b }}-{{ c }}{% endwith %}",
      { 'value' => [1, [2, 3]] },
    )
  end

  def test_empty_array_pattern_matches_an_empty_array
    assert_template_result(
      "ok",
      "{% with [] = items %}ok{% endwith %}",
      { 'items' => [] },
    )
  end

  def test_empty_array_pattern_rejects_a_non_empty_array
    error = assert_raises(PatternMatchError) do
      Liquid::Template.parse("{% with [] = items %}ok{% endwith %}").render!('items' => [1])
    end
    assert_match(/Pattern matching failed at \$: array length/, error.message)
  end

  def test_extra_array_elements_fail_without_a_rest_at_the_pattern
    error = assert_raises(PatternMatchError) do
      Liquid::Template.parse("{% with [a] = items %}{% endwith %}").render!('items' => [1, 2])
    end
    assert_match(/Pattern matching failed at \$: array length/, error.message)
  end

  def test_missing_required_array_element_fails_at_its_index
    error = assert_raises(PatternMatchError) do
      Liquid::Template.parse("{% with [a, b] = items %}{% endwith %}").render!('items' => [1])
    end
    assert_match(/Pattern matching failed at \[1\]: value is missing/, error.message)
  end

  # --- Array rest pattern ----------------------------------------------------

  def test_array_rest_collects_remaining_items
    assert_template_result(
      "1|2,3",
      "{% with [first, *rest] = items %}{{ first }}|{{ rest | join: ',' }}{% endwith %}",
      { 'items' => [1, 2, 3] },
    )
  end

  def test_array_rest_binds_an_empty_array_when_nothing_remains
    assert_template_result(
      "0",
      "{% with [first, *rest] = items %}{{ rest.size }}{% endwith %}",
      { 'items' => [1] },
    )
  end

  # --- Object destructuring --------------------------------------------------

  def test_destructures_an_object_by_key
    assert_template_result(
      "Ada|30",
      "{% with { name: n, age: a } = user %}{{ n }}|{{ a }}{% endwith %}",
      { 'user' => { 'name' => 'Ada', 'age' => 30 } },
    )
  end

  def test_object_keys_may_be_quoted
    assert_template_result(
      "Ada",
      "{% with { 'full name': n } = user %}{{ n }}{% endwith %}",
      { 'user' => { 'full name' => 'Ada' } },
    )
  end

  def test_nested_object_destructuring
    assert_template_result(
      "Ada",
      "{% with { profile: { name: n } } = payload %}{{ n }}{% endwith %}",
      { 'payload' => { 'profile' => { 'name' => 'Ada' } } },
    )
  end

  def test_object_rest_collects_remaining_keys
    assert_template_result(
      "1|2",
      "{% with { a: x, *rest } = obj %}{{ x }}|{{ rest.b }}{% endwith %}",
      { 'obj' => { 'a' => 1, 'b' => 2 } },
    )
  end

  def test_object_rest_binds_an_empty_hash_when_nothing_remains
    assert_template_result(
      "0",
      "{% with { a: x, *rest } = obj %}{{ rest.size }}{% endwith %}",
      { 'obj' => { 'a' => 1 } },
    )
  end

  # --- Default expressions ---------------------------------------------------

  def test_default_is_used_for_a_missing_array_index
    assert_template_result(
      "guest|none",
      "{% with [name = 'guest', role = 'none'] = items %}{{ name }}|{{ role }}{% endwith %}",
      { 'items' => [] },
    )
  end

  def test_default_is_skipped_for_an_explicit_nil_array_item
    assert_template_result(
      "|x",
      "{% with [a = 'd', b = 'd'] = items %}{{ a }}|{{ b }}{% endwith %}",
      { 'items' => [nil, 'x'] },
    )
  end

  def test_default_is_used_for_a_missing_object_key
    assert_template_result(
      "guest",
      "{% with { name: n = 'guest' } = user %}{{ n }}{% endwith %}",
      { 'user' => {} },
    )
  end

  def test_default_is_skipped_for_an_explicit_nil_object_value
    assert_template_result(
      "|",
      "{% with { a: x = 'd', b: y = 'd' } = obj %}{{ x }}|{{ y }}{% endwith %}",
      { 'obj' => { 'a' => nil, 'b' => nil } },
    )
  end

  def test_nested_defaults
    assert_template_result(
      "guest|none|0",
      "{% with { name: n = 'guest', perms: [first = 'none', *rest] = no_perms } = payload %}" \
        "{{ n }}|{{ first }}|{{ rest.size }}{% endwith %}",
      { 'payload' => {}, 'no_perms' => [] },
    )
  end

  def test_default_expression_can_reference_outer_variables
    assert_template_result(
      "fallback",
      "{% with { role: r = fallback } = payload %}{{ r }}{% endwith %}",
      { 'payload' => {}, 'fallback' => 'fallback' },
    )
  end

  def test_default_expression_can_use_filters
    assert_template_result(
      "NEVER",
      "{% with { ts: t = now | default: 'never' | upcase } = payload %}{{ t }}{% endwith %}",
      { 'payload' => {} },
    )
  end

  def test_default_on_a_nested_array_pattern
    assert_template_result(
      "x|0",
      "{% with { tags: [first = 'x', *rest] = empty_tags } = payload %}{{ first }}|{{ rest.size }}{% endwith %}",
      { 'payload' => {}, 'empty_tags' => [] },
    )
  end

  # --- Matching failures -----------------------------------------------------

  def test_failure_path_points_at_the_specific_array_index
    error = assert_raises(PatternMatchError) do
      Liquid::Template
        .parse("{% with [a, [b, c]] = value %}{% endwith %}")
        .render!('value' => [1, [2]])
    end
    expected = "Liquid error: Pattern matching failed at [1][1]: value is missing and no default was provided"
    assert_equal(expected, error.message)
  end

  def test_failure_path_points_at_the_specific_object_key
    error = assert_raises(PatternMatchError) do
      Liquid::Template
        .parse("{% with { user: { roles: [a, b] } } = payload %}{% endwith %}")
        .render!('payload' => { 'user' => { 'roles' => ['only'] } })
    end
    assert_equal(
      "Liquid error: Pattern matching failed at .user.roles[1]: value is missing and no default was provided",
      error.message,
    )
  end

  def test_failure_when_a_missing_key_has_no_default
    error = assert_raises(PatternMatchError) do
      Liquid::Template.parse("{% with { a: x } = obj %}{% endwith %}").render!('obj' => {})
    end
    assert_match(/Pattern matching failed at \.a: value is missing/, error.message)
  end

  def test_failure_when_value_is_not_an_array
    error = assert_raises(PatternMatchError) do
      Liquid::Template.parse("{% with [a] = value %}{% endwith %}").render!('value' => 'nope')
    end
    assert_match(/Pattern matching failed at \$: expected an array/, error.message)
  end

  def test_failure_when_value_is_not_an_object
    error = assert_raises(PatternMatchError) do
      Liquid::Template.parse("{% with { a: x } = value %}{% endwith %}").render!('value' => 'nope')
    end
    assert_match(/Pattern matching failed at \$: expected an object/, error.message)
  end

  def test_failed_binding_is_atomic
    # `a` matches before `c` (index 2) is found missing, but because matching
    # fails the body never runs: `a` is not rendered and nothing leaks.
    output = Liquid::Template.parse(
      "before|{% with [a, b, c] = items %}{{ a }}{% endwith %}|after",
    ).render('items' => [1, 2], 'a' => 'outer')

    assert_match(/before\|Liquid error: Pattern matching failed at \[2\]:.*\|after/, output)
  end

  def test_failed_match_does_not_shadow_the_outer_variable
    output = Liquid::Template.parse(
      "{% with [a, b] = items %}{{ a }}{% endwith %}|{{ a }}",
    ).render('items' => [1], 'a' => 'outer')

    assert_match(/Pattern matching failed at \[1\].*\|outer/, output)
  end

  def test_render_error_surfaces_in_lax_mode
    output = Liquid::Template.parse("{% with { a: x } = obj %}{{ x }}{% endwith %}")
      .render({ 'obj' => {} })
    assert_match(/Liquid error.*Pattern matching failed at \.a/, output)
  end

  # --- Parse-time validation -------------------------------------------------

  def test_duplicate_variable_names_are_rejected
    error = assert_raises(SyntaxError) do
      Liquid::Template.parse("{% with [a, a] = value %}{% endwith %}")
    end
    assert_match(/Variable 'a' is bound more than once/, error.message)
  end

  def test_duplicate_variable_across_nested_patterns_is_rejected
    error = assert_raises(SyntaxError) do
      Liquid::Template.parse("{% with { a: x, b: { c: x } } = value %}{% endwith %}")
    end
    assert_match(/Variable 'x' is bound more than once/, error.message)
  end

  def test_duplicate_object_keys_are_rejected
    error = assert_raises(SyntaxError) do
      Liquid::Template.parse("{% with { a: x, a: y } = value %}{% endwith %}")
    end
    assert_match(/Object key 'a' is listed more than once/, error.message)
  end

  def test_rest_must_be_the_last_array_element
    error = assert_raises(SyntaxError) do
      Liquid::Template.parse("{% with [*rest, a] = value %}{% endwith %}")
    end
    assert_match(/\*rest.*last element/, error.message)
  end

  def test_no_elements_may_follow_an_array_rest
    error = assert_raises(SyntaxError) do
      Liquid::Template.parse("{% with [a, *rest, b] = value %}{% endwith %}")
    end
    assert_match(/\*rest.*last element/, error.message)
  end

  def test_rest_must_be_the_last_object_pair
    error = assert_raises(SyntaxError) do
      Liquid::Template.parse("{% with { *rest, a: x } = value %}{% endwith %}")
    end
    assert_match(/\*rest.*last element/, error.message)
  end

  def test_rest_cannot_have_a_default
    error = assert_raises(SyntaxError) do
      Liquid::Template.parse("{% with [*rest = 'x'] = value %}{% endwith %}")
    end
    assert_match(/\*rest.*default/, error.message)
  end

  def test_rest_is_not_allowed_at_the_root
    error = assert_raises(SyntaxError) do
      Liquid::Template.parse("{% with *rest = value %}{% endwith %}")
    end
    assert_match(/only valid inside \[\] or \{\}/, error.message)
  end

  def test_missing_equals_sign_is_a_syntax_error
    error = assert_raises(SyntaxError) do
      Liquid::Template.parse("{% with x value %}{% endwith %}")
    end
    assert_match(/Valid syntax: with/, error.message)
  end

  def test_unclosed_array_pattern_is_a_syntax_error
    error = assert_raises(SyntaxError) do
      Liquid::Template.parse("{% with [a, b = value %}{% endwith %}")
    end
    assert_match(/missing a closing '\]'/, error.message)
  end

  def test_unclosed_object_pattern_is_a_syntax_error
    error = assert_raises(SyntaxError) do
      Liquid::Template.parse("{% with { a: x = value %}{% endwith %}")
    end
    assert_match(/missing a closing '\}'/, error.message)
  end

  def test_object_key_without_colon_is_a_syntax_error
    error = assert_raises(SyntaxError) do
      Liquid::Template.parse("{% with { a x } = value %}{% endwith %}")
    end
    assert_match(/Object key must be followed by ':'/, error.message)
  end

  def test_empty_value_expression_is_a_syntax_error
    error = assert_raises(SyntaxError) do
      Liquid::Template.parse("{% with x = %}{% endwith %}")
    end
    assert_match(/Missing value expression/, error.message)
  end

  def test_empty_default_expression_is_a_syntax_error
    error = assert_raises(SyntaxError) do
      Liquid::Template.parse("{% with [a = ] = value %}{% endwith %}")
    end
    assert_match(/Missing default expression/, error.message)
  end

  def test_rest_position_checks_apply_in_every_parser_mode
    with_error_modes(:lax, :strict, :strict2) do
      assert_raises(SyntaxError) do
        Liquid::Template.parse("{% with [*a, b] = value %}{% endwith %}")
      end
    end
  end

  # --- End-to-end rendered examples ------------------------------------------

  def test_documentation_example_with_user_and_permissions
    template = "{% with [user, permissions = no_perms] = payload %}" \
      "{{ user.name }} ({{ permissions | join: ', ' | default: 'no permissions' }}){% endwith %}"

    assert_template_result(
      "Ada (read, write)",
      template,
      { 'payload' => [{ 'name' => 'Ada' }, %w[read write]], 'no_perms' => [] },
    )
  end

  def test_documentation_example_with_empty_permissions_array
    template = "{% with [user, permissions = no_perms] = payload %}" \
      "{{ user.name }} ({{ permissions.size }}){% endwith %}"

    assert_template_result(
      "Ada (0)",
      template,
      { 'payload' => [{ 'name' => 'Ada' }], 'no_perms' => [] },
    )
  end

  def test_documentation_example_with_missing_object_keys_and_nested_defaults
    template = "{% with { name: title = 'Guest', perms: [first = 'none', *rest] = no_perms } = payload %}" \
      "{{ title }}:{{ first }}:+{{ rest.size }}{% endwith %}"

    assert_template_result(
      "Guest:none:+0",
      template,
      { 'payload' => {}, 'no_perms' => [] },
    )
  end

  # --- Parse tree ------------------------------------------------------------

  def test_parse_tree_visitor_exposes_value_and_default_expressions
    template = Liquid::Template.parse(
      "{% with { a: x = fallback, b: [y, *rest] } = payload %}{{ x }}{% endwith %}",
    )
    tag = template.root.nodelist.first

    children = Liquid::ParseTreeVisitor.for(tag).children

    assert_equal(2, children.length)
    assert_equal('payload', children.first.name.name)
    assert_equal('fallback', children.last.name.name)
  end
end
