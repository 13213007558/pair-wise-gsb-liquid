# frozen_string_literal: true

require 'test_helper'

class DestructurableUserDrop < Liquid::Drop
  def name
    'Drop User'
  end
end

class DestructureTagTest < Minitest::Test
  include Liquid

  def test_basic_array_destructure
    assert_template_result(
      'Ada can read,write',
      '{% destructure [user, permissions] = payload %}{{ user.name }} can {{ permissions | join: "," }}{% enddestructure %}',
      { 'payload' => [{ 'name' => 'Ada' }, %w(read write)] },
    )
  end

  def test_nested_array_pattern
    assert_template_result(
      '1-2-3',
      '{% destructure [first, [second, third]] = list %}{{ first }}-{{ second }}-{{ third }}{% enddestructure %}',
      { 'list' => [1, [2, 3]] },
    )
  end

  def test_object_pattern_with_shorthand_and_alias
    assert_template_result(
      'Ada <ada@example.com>',
      '{% destructure {name, email: mail} = user %}{{ name }} <{{ mail }}>{% enddestructure %}',
      { 'user' => { 'name' => 'Ada', 'email' => 'ada@example.com' } },
    )
  end

  def test_bare_variable_pattern
    assert_template_result(
      'Ada',
      '{% destructure u = user %}{{ u.name }}{% enddestructure %}',
      { 'user' => { 'name' => 'Ada' } },
    )
  end

  def test_array_rest_pattern
    assert_template_result(
      '1|2,3',
      '{% destructure [head, *tail] = list %}{{ head }}|{{ tail | join: "," }}{% enddestructure %}',
      { 'list' => [1, 2, 3] },
    )
  end

  def test_object_rest_pattern
    assert_template_result(
      'Ada|30',
      '{% destructure {name, **rest} = user %}{{ name }}|{{ rest.age }}{% enddestructure %}',
      { 'user' => { 'name' => 'Ada', 'age' => 30 } },
    )
  end

  # --- Empty arrays -------------------------------------------------------

  def test_empty_array_binds_empty_rest
    assert_template_result(
      'rest=0',
      '{% destructure [*rest] = empty_list %}rest={{ rest.size }}{% enddestructure %}',
      { 'empty_list' => [] },
    )
  end

  def test_empty_array_fails_required_position_and_binding_does_not_apply
    # [first, *rest]: the "first" sub-pattern has no value to match (empty
    # array), so the whole binding fails and the outer "first" stays visible.
    assert_template_result(
      'outer|',
      '{% destructure [first, *rest] = empty_list %}{{ first }}|{{ rest | join: "," }}{% enddestructure %}',
      { 'empty_list' => [], 'first' => 'outer' },
    )
  end

  # --- Missing object keys ------------------------------------------------

  def test_missing_object_key_uses_default
    assert_template_result(
      'anonymous',
      "{% destructure {name = 'anonymous'} = user %}{{ name }}{% enddestructure %}",
      { 'user' => {} },
    )
  end

  def test_explicit_nil_is_not_missing
    # The key exists with a nil value, so the default must NOT apply.
    assert_template_result(
      '[]',
      "{% destructure {name = 'anonymous'} = user %}[{{ name }}]{% enddestructure %}",
      { 'user' => { 'name' => nil } },
    )
    # Same for array positions: an explicit nil element is a real value.
    assert_template_result(
      '[]',
      '{% destructure [item = 5] = list %}[{{ item }}]{% enddestructure %}',
      { 'list' => [nil] },
    )
  end

  def test_missing_object_key_without_default_fails_whole_binding
    # The "{name}" sub-pattern fails because "user" has no "name" key, so
    # none of the bindings take effect, not even "email" which did match.
    assert_template_result(
      '|',
      '{% destructure {name, email} = user %}{{ name }}|{{ email }}{% enddestructure %}',
      { 'user' => { 'email' => 'ada@example.com' } },
    )
  end

  # --- Nested defaults ----------------------------------------------------

  def test_nested_defaults
    template = '{% destructure {user: {name = "anonymous"} = fallback_user} = payload %}{{ name }}{% enddestructure %}'

    # "user" key is missing: the outer default supplies the value for the
    # nested object pattern, which then finds "name" inside it.
    assert_template_result('Ada', template, {
      'payload' => {},
      'fallback_user' => { 'name' => 'Ada' },
    })

    # The outer default itself lacks "name": the nested default applies.
    assert_template_result('anonymous', template, {
      'payload' => {},
      'fallback_user' => {},
    })

    # Everything present: no default is used.
    assert_template_result('Bob', template, {
      'payload' => { 'user' => { 'name' => 'Bob' } },
      'fallback_user' => { 'name' => 'Ada' },
    })
  end

  def test_default_expressions_may_contain_commas_and_lookups
    assert_template_result(
      'x,y|fallback',
      "{% destructure [a = 'x,y', b = fallback.name] = empty_list %}{{ a }}|{{ b }}{% enddestructure %}",
      { 'empty_list' => [], 'fallback' => { 'name' => 'fallback' } },
    )
  end

  # --- Failure position maps to a concrete pattern ------------------------

  def test_failure_in_second_element_pattern_fails_whole_binding
    template = '{% destructure [{name: first}, {name: second}] = users %}{{ first }}-{{ second }}{% enddestructure %}'

    # Both sub-patterns match.
    assert_template_result('a-b', template, {
      'users' => [{ 'name' => 'a' }, { 'name' => 'b' }],
    })

    # The second "{name: second}" sub-pattern fails (missing "name" key):
    # the whole binding is discarded, so even "first" stays unbound.
    assert_template_result('-', template, {
      'users' => [{ 'name' => 'a' }, {}],
    })

    # The first "{name: first}" sub-pattern fails: same atomic failure.
    assert_template_result('-', template, {
      'users' => [{}, { 'name' => 'b' }],
    })
  end

  def test_failure_in_nested_array_pattern
    # The nested "[y]" sub-pattern fails because the inner array is empty.
    assert_template_result(
      '-',
      '{% destructure [x, [y]] = list %}{{ x }}-{{ y }}{% enddestructure %}',
      { 'list' => [1, []] },
    )
  end

  def test_array_pattern_against_non_array_fails
    assert_template_result(
      '|',
      '{% destructure [a] = not_an_array %}{{ a }}{% enddestructure %}|',
      { 'not_an_array' => 'string' },
    )
  end

  # --- Scoping ------------------------------------------------------------

  def test_outer_variable_with_same_name_is_restored_after_block
    assert_template_result(
      'inner|outer',
      "{% assign name = 'outer' %}{% destructure {name} = user %}{{ name }}{% enddestructure %}|{{ name }}",
      { 'user' => { 'name' => 'inner' } },
    )
  end

  def test_bindings_do_not_leak_out_of_block
    assert_template_result(
      'inner|',
      '{% destructure {name} = user %}{{ name }}{% enddestructure %}|{{ name }}',
      { 'user' => { 'name' => 'inner' } },
    )
  end

  # --- Drops --------------------------------------------------------------

  def test_object_pattern_against_drop
    assert_template_result(
      'Drop User|unknown',
      '{% destructure {name, missing = "unknown"} = user %}{{ name }}|{{ missing }}{% enddestructure %}',
      { 'user' => DestructurableUserDrop.new },
    )
  end

  # --- Parse-time errors --------------------------------------------------

  def test_duplicate_variable_is_rejected
    assert_match_syntax_error(
      /Syntax Error in 'destructure' - Duplicate variable 'name' in pattern \{name, name\}/,
      '{% destructure {name, name} = user %}{% enddestructure %}',
    )
  end

  def test_duplicate_variable_across_nesting_is_rejected
    assert_match_syntax_error(
      /Duplicate variable 'name' in pattern \{user: \{name\}, name\}/,
      '{% destructure {user: {name}, name} = payload %}{% enddestructure %}',
    )
  end

  def test_duplicate_variable_with_rest_is_rejected
    assert_match_syntax_error(
      /Duplicate variable 'a' in pattern \[a, \*a\]/,
      '{% destructure [a, *a] = list %}{% enddestructure %}',
    )
  end

  def test_rest_in_non_last_position_is_rejected
    assert_match_syntax_error(
      /Rest item '\*head' must be the last item in pattern \[\*head, tail\]/,
      '{% destructure [*head, tail] = list %}{% enddestructure %}',
    )
  end

  def test_multiple_rests_are_rejected
    assert_match_syntax_error(
      /Rest item '\*a' must be the last item in pattern \[\*a, \*b\]/,
      '{% destructure [*a, *b] = list %}{% enddestructure %}',
    )
  end

  def test_object_rest_in_non_last_position_is_rejected
    assert_match_syntax_error(
      /Rest item '\*\*rest' must be the last item in pattern \{\*\*rest, name\}/,
      '{% destructure {**rest, name} = user %}{% enddestructure %}',
    )
  end

  def test_missing_equals_sign_is_rejected
    assert_match_syntax_error(
      "Syntax Error in 'destructure' - Valid syntax: destructure [pattern] = [expression]",
      '{% destructure [a, b] %}{% enddestructure %}',
    )
  end

  def test_invalid_pattern_is_rejected
    assert_match_syntax_error(
      /expected a variable name, '\[' or '\{' in pattern \[a, ,\]/,
      '{% destructure [a, ,] = list %}{% enddestructure %}',
    )
  end

  def test_tag_never_closed
    assert_match_syntax_error(
      /'destructure' tag was never closed/,
      '{% destructure [a] = list %}',
    )
  end

  def test_works_in_strict2_mode
    assert_template_result(
      'Ada',
      '{% destructure {name} = user %}{{ name }}{% enddestructure %}',
      { 'user' => { 'name' => 'Ada' } },
      error_mode: :strict2,
    )
  end
end
