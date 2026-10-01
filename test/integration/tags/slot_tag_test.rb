# frozen_string_literal: true

require 'test_helper'

class SlotTagTest < Minitest::Test
  include Liquid

  def test_slot_renders_default_content_when_not_supplied
    assert_template_result(
      'hello world',
      '{% render "card" %}',
      partials: { 'card' => 'hello {% slot actions %}world{% endslot %}' },
    )
  end

  def test_slot_without_default_content_renders_nothing
    assert_template_result(
      'hello',
      '{% render "card" %}',
      partials: { 'card' => 'hello{% slot actions %}{% endslot %}' },
    )
  end

  def test_slot_is_rendered_at_specified_position
    assert_template_result(
      'A-default-B',
      '{% render "card" %}',
      partials: { 'card' => 'A-{% slot actions %}default{% endslot %}-B' },
    )
  end

  def test_supplied_slot_overrides_default_content
    assert_template_result(
      'A-custom-B',
      '{% render "card" %}{% slot actions %}custom{% endslot %}{% endrender %}',
      partials: { 'card' => 'A-{% slot actions %}default{% endslot %}-B' },
    )
  end

  def test_unknown_slot_blocks_are_ignored
    assert_template_result(
      'default',
      '{% render "card" %}{% slot unused %}custom{% endslot %}{% endrender %}',
      partials: { 'card' => '{% slot actions %}default{% endslot %}' },
    )
  end

  def test_empty_render_block
    assert_template_result(
      'default',
      '{% render "card" %}{% endrender %}',
      partials: { 'card' => '{% slot actions %}default{% endslot %}' },
    )
  end

  def test_multiple_named_slots
    assert_template_result(
      'T / B / f',
      '{% render "card" %}{% slot title %}T{% endslot %}{% slot body %}B{% endslot %}{% endrender %}',
      partials: {
        'card' => '{% slot title %}t{% endslot %} / ' \
          '{% slot body %}b{% endslot %} / {% slot footer %}f{% endslot %}',
      },
    )
  end

  def test_slot_reads_caller_local_variables
    assert_template_result(
      'outer value',
      '{% assign greeting = "outer value" %}' \
        '{% render "card" %}{% slot actions %}{{ greeting }}{% endslot %}{% endrender %}',
      partials: { 'card' => '{% slot actions %}default{% endslot %}' },
    )
  end

  def test_slot_reads_render_parameters
    assert_template_result(
      '42',
      '{% render "card", answer: 42 %}{% slot actions %}{{ answer }}{% endslot %}{% endrender %}',
      partials: { 'card' => '{% slot actions %}0{% endslot %}' },
    )
  end

  def test_slot_does_not_inherit_variables_created_inside_the_snippet
    assert_template_result(
      '',
      '{% render "card" %}{% slot actions %}{{ secret }}{% endslot %}{% endrender %}',
      partials: { 'card' => '{% assign secret = 1 %}{% slot actions %}default{% endslot %}' },
    )
  end

  def test_snippet_variables_cannot_leak_through_slot_rendering
    assert_template_result(
      '',
      '{% render "card" %}{% slot actions %}{{ secret }}{% endslot %}{% endrender %}{{ secret }}',
      partials: { 'card' => '{% assign secret = 1 %}{% slot actions %}{% endslot %}' },
    )
  end

  def test_variables_assigned_in_a_slot_do_not_leak_to_the_caller
    assert_template_result(
      'in=1|out=',
      '{% render "card" %}{% slot actions %}{% assign tmp = 1 %}in={{ tmp }}{% endslot %}{% endrender %}|out={{ tmp }}',
      partials: { 'card' => '{% slot actions %}{% endslot %}' },
    )
  end

  def test_slot_can_be_used_multiple_times
    assert_template_result(
      'x-x-',
      '{% render "card" %}{% slot actions %}x{% endslot %}{% endrender %}',
      partials: { 'card' => '{% slot actions %}d{% endslot %}-{% slot actions %}d{% endslot %}-' },
    )
  end

  def test_default_content_is_used_multiple_times
    assert_template_result(
      'd-d-',
      '{% render "card" %}',
      partials: { 'card' => '{% slot actions %}d{% endslot %}-{% slot actions %}d{% endslot %}-' },
    )
  end

  def test_slot_is_evaluated_lazily
    drop = Class.new(Liquid::Drop) do
      class << self
        attr_accessor :reads
      end
      def expensive
        self.class.reads << :expensive
        'expensive'
      end
    end
    drop.reads = []

    assert_template_result(
      'custom',
      '{% render "card", thing: thing %}{% slot actions %}custom{% endslot %}{% endrender %}',
      { 'thing' => drop.new },
      partials: { 'card' => '{% slot actions %}{{ thing.expensive }}{% endslot %}' },
    )
    assert_empty(drop.reads)
  end

  def test_default_content_is_evaluated_lazily
    drop = Class.new(Liquid::Drop) do
      class << self
        attr_accessor :reads
      end
      def expensive
        self.class.reads << :expensive
        'expensive'
      end
    end
    drop.reads = []

    partials = { 'card' => '{% if false %}{% slot actions %}{{ thing.expensive }}{% endslot %}{% endif %}' }

    assert_template_result(
      '',
      '{% render "card", thing: thing %}{% slot actions %}custom{% endslot %}{% endrender %}',
      { 'thing' => drop.new },
      partials: partials,
    )
    assert_empty(drop.reads)

    assert_template_result(
      'expensive',
      '{% render "card", thing: thing %}',
      { 'thing' => drop.new },
      partials: { 'card' => '{% if true %}{% slot actions %}{{ thing.expensive }}{% endslot %}{% endif %}' },
    )
    assert_equal([:expensive], drop.reads)
  end

  def test_unused_supplied_slot_is_not_evaluated
    drop = Class.new(Liquid::Drop) do
      class << self
        attr_accessor :reads
      end
      def expensive
        self.class.reads << :expensive
        'expensive'
      end
    end
    drop.reads = []

    assert_template_result(
      '',
      '{% render "card", thing: thing %}{% slot actions %}{{ thing.expensive }}{% endslot %}{% endrender %}',
      { 'thing' => drop.new },
      partials: { 'card' => '' },
    )
    assert_empty(drop.reads)
  end

  def test_slot_render_for_binds_parameters_independently_per_iteration
    assert_template_result(
      'one|two|',
      '{% render "card" for items as item %}{% slot actions %}{{ item }}{% endslot %}{% endrender %}',
      { 'items' => %w[one two] },
      partials: { 'card' => '{% slot actions %}{% endslot %}|' },
    )
  end

  def test_slot_bindings_are_independent_across_render_for_iterations
    # Each invocation gets its own binding snapshot. Capturing the item into a
    # variable inside the first rendering of the slot can't shadow the item
    # seen by the same slot on the next iteration or on repeated use.
    template = '{% render "card" for items as item %}' \
      '{% slot actions %}[{{ item }}]{% endslot %}{% endrender %}'
    partials = { 'card' => '{% slot actions %}{% endslot %}{% slot actions %}{% endslot %}' }
    assert_template_result(
      '[one][one][two][two]',
      template,
      { 'items' => %w[one two] },
      partials: partials,
    )
  end

  def test_slot_assignment_scope_is_fresh_per_render_for_iteration
    # A capture taken inside the slot on the first iteration must not be
    # visible on the second iteration, because each invocation renders in an
    # isolated context.
    template = '{% render "card" for items as item %}' \
      '{% slot actions %}{% capture seen %}{{ item }}{% endcapture %}{{ seen }}{% endslot %}' \
      '{% endrender %}'
    partials = { 'card' => '{% slot actions %}{% endslot %}' }
    assert_template_result(
      'onetwo',
      template,
      { 'items' => %w[one two] },
      partials: partials,
    )
    assert_template_result(
      '',
      '{% render "card" for items as item %}' \
        '{% slot actions %}{% assign seen = item %}{% endslot %}{% endrender %}{{ seen }}',
      { 'items' => %w[one two] },
      partials: partials,
    )
  end

  def test_slot_used_twice_keeps_invocations_independent
    assert_template_result(
      'one:one|two:two|',
      '{% render "card" for items as item %}' \
        '{% slot actions %}{{ item }}:{{ item }}{% endslot %}{% endrender %}',
      { 'items' => %w[one two] },
      partials: { 'card' => '{% slot actions %}{% endslot %}|' },
    )
  end

  def test_slot_reads_variables_of_an_enclosing_for_loop
    assert_template_result(
      '1a|2a|',
      '{% for n in nums %}{% render "card" %}{% slot actions %}{{ n }}a{% endslot %}{% endrender %}{% endfor %}',
      { 'nums' => [1, 2] },
      partials: { 'card' => '{% slot actions %}{% endslot %}|' },
    )
  end

  def test_slots_forward_through_nested_renders
    partials = {
      'outer' => '{% render "inner" with message as message, title: title %}',
      'inner' => '{{ title }}:{% slot actions %}default{% endslot %}|',
    }
    assert_template_result(
      'Inbox:hello|Inbox:world|',
      '{% render "outer" for messages as message, title: "Inbox" %}' \
        '{% slot actions %}{{ message }}{% endslot %}{% endrender %}',
      { 'messages' => %w[hello world] },
      partials: partials,
    )
  end

  def test_inner_render_can_override_a_forwarded_slot
    # The outer snippet forwards the caller's slots to the inner one, but the
    # inner snippet can fall back to its own default when no slot is supplied.
    partials = {
      'outer' => '{% render "inner" %}',
      'inner' => '{% slot actions %}inner-default{% endslot %}',
    }
    assert_template_result(
      'caller',
      '{% render "outer" %}{% slot actions %}caller{% endslot %}{% endrender %}',
      partials: partials,
    )
    assert_template_result(
      'inner-default',
      '{% render "outer" %}',
      partials: partials,
    )
  end

  def test_snippet_defined_slot_blocks_are_rendered_by_nested_snippets
    # A snippet can itself use the render block form to provide slot content to
    # a further nested snippet. That content shadows the nested snippet's
    # default content, just like content supplied by a top level caller does.
    partials = {
      'outer' => '{% render "inner" %}{% slot actions %}outer{% endslot %}{% endrender %}',
      'inner' => '{% slot actions %}inner-default{% endslot %}',
    }
    assert_template_result(
      'outer',
      '{% render "outer" %}',
      partials: partials,
    )

    # The nested snippet still falls back to its default content when neither
    # its caller nor an enclosing caller supplies the slot.
    partials2 = {
      'outer' => '{% render "inner" %}',
      'inner' => '{% slot actions %}inner-default{% endslot %}',
    }
    assert_template_result(
      'inner-default',
      '{% render "outer" %}',
      partials: partials2,
    )
  end

  def test_includes_will_not_render_inside_slot_content
    assert_template_result(
      'Liquid error (outer line 1): include usage is not allowed in this context',
      '{% render "outer" %}{% slot actions %}{% include "foo" %}{% endslot %}{% endrender %}',
      render_errors: true,
      partials: {
        'foo' => 'bar',
        'outer' => '{% slot actions %}default{% endslot %}',
      },
    )
  end

  def test_slot_requires_a_name
    assert_syntax_error(
      '{% render "card" %}{% slot %}{% endslot %}{% endrender %}',
    )
  end

  def test_duplicate_slot_names_raise_a_syntax_error
    err = assert_raises(Liquid::SyntaxError) do
      Liquid::Template.parse(
        '{% render "card" %}{% slot actions %}a{% endslot %}{% slot actions %}b{% endslot %}{% endrender %}',
      )
    end
    assert_match(/actions/, err.message)
  end

  def test_non_slot_content_in_render_block_raises_a_syntax_error
    assert_raises(Liquid::SyntaxError) do
      Liquid::Template.parse(
        '{% render "card" %}not allowed{% endrender %}',
      )
    end
  end

  def test_non_slot_tags_in_render_block_raise_a_syntax_error
    assert_raises(Liquid::SyntaxError) do
      Liquid::Template.parse(
        '{% render "card" %}{% if true %}x{% endif %}{% endrender %}',
      )
    end
  end

  def test_unterminated_render_block_raises_a_syntax_error
    assert_raises(Liquid::SyntaxError) do
      Liquid::Template.parse(
        '{% render "card" %}{% slot actions %}a{% endslot %}',
      )
    end
  end

  def test_unterminated_slot_block_raises_a_syntax_error
    assert_raises(Liquid::SyntaxError) do
      Liquid::Template.parse(
        '{% render "card" %}{% slot actions %}a{% endrender %}',
      )
    end
  end

  def test_slot_tag_works_in_liquid_tag
    assert_template_result(
      'custom',
      "{% liquid\nrender 'card'\nslot actions\ncustom\nendslot\nendrender %}",
      partials: { 'card' => '{% slot actions %}default{% endslot %}' },
    )
  end

  def test_render_without_block_still_works_next_to_other_content
    assert_template_result(
      'before-default-after',
      'before-{% render "card" %}-after',
      partials: { 'card' => '{% slot actions %}default{% endslot %}' },
    )
  end

  def test_nested_snippets_with_loop_render_same_title_and_different_actions
    partials = {
      'mail_card' => '{{ title }}:{% slot actions %}default{% endslot %}|',
      'mail_list' => "{% render 'mail_card' for messages as message, title: title %}{% endrender %}",
    }
    assert_template_result(
      'Inbox:read|Inbox:archive|',
      '{% render "mail_list", messages: messages, title: "Inbox" %}' \
        '{% slot actions %}' \
        '{% if message.unread %}read{% else %}archive{% endif %}' \
        '{% endslot %}{% endrender %}',
      {
        'messages' => [
          { 'unread' => true },
          { 'unread' => false },
        ],
      },
      partials: partials,
    )
  end

  def test_default_drop_method_is_not_read_when_slot_is_never_rendered
    drop = Class.new(Liquid::Drop) do
      class << self
        attr_accessor :reads
      end
      def expensive
        self.class.reads << :expensive
        'expensive'
      end
    end
    drop.reads = []

    # The snippet never renders the slot at all, so neither the supplied
    # content nor the default content (which reads the drop) is evaluated.
    assert_template_result(
      '',
      '{% render "card", thing: thing %}' \
        '{% slot actions %}{{ thing.expensive }}{% endslot %}{% endrender %}',
      { 'thing' => drop.new },
      partials: { 'card' => '' },
    )
    assert_empty(drop.reads)
  end
end
