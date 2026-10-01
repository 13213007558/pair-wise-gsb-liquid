# frozen_string_literal: true

require 'test_helper'

# A drop that records how many times each attribute was read, so tests can
# prove that lazily skipped slot content never touches its data.
class SlotReadTrackingDrop < Liquid::Drop
  def initialize(values = {})
    @values = values
    @reads  = Hash.new(0)
  end

  attr_reader :reads

  def liquid_method_missing(key)
    @reads[key] += 1
    @values[key]
  end
end

class RenderSlotTagTest < Minitest::Test
  include Liquid

  # ------------------------------------------------------------------ basics

  def test_slot_renders_default_content_when_not_supplied
    assert_template_result(
      'actions: default',
      "{% render 'card' %}",
      partials: { 'card' => "actions: {% slot actions %}default{% endslot %}" },
    )
  end

  def test_slot_renders_supplied_content
    assert_template_result(
      'actions: <a href="/buy">Buy</a>',
      "{% render 'card' %}{% slot actions %}<a href=\"/buy\">Buy</a>{% endslot %}{% endrender %}",
      partials: { 'card' => "actions: {% slot actions %}default{% endslot %}" },
    )
  end

  def test_slot_name_may_be_a_quoted_string
    assert_template_result(
      'supplied',
      "{% render 'card' %}{% slot 'actions' %}supplied{% endslot %}{% endrender %}",
      partials: { 'card' => "{% slot 'actions' %}default{% endslot %}" },
    )
  end

  def test_body_less_render_still_works_next_to_other_tags
    assert_template_result(
      'AcardB!',
      "A{% render 'card' %}B{% if true %}!{% endif %}",
      partials: { 'card' => 'card' },
    )
  end

  def test_body_less_render_followed_by_a_loop
    assert_template_result(
      'C xx',
      "{% render 'card' %} {% for i in (1..2) %}x{% endfor %}",
      partials: { 'card' => 'C' },
    )
  end

  def test_body_less_render_followed_by_an_output
    assert_template_result(
      'C7',
      "{% render 'card' %}{{ v }}",
      { 'v' => 7 },
      partials: { 'card' => 'C' },
    )
  end

  def test_render_body_only_accepts_slot_tags
    with_error_modes(:strict, :strict2, :lax) do
      assert_syntax_error(
        "{% render 'card' %}plain text{% endrender %}",
      )
    end
  end

  def test_render_body_rejects_duplicate_slot_names
    assert_syntax_error(
      "{% render 'card' %}{% slot actions %}a{% endslot %}{% slot actions %}b{% endslot %}{% endrender %}",
    )
  end

  def test_supplying_an_unknown_slot_is_allowed_but_ignored
    assert_template_result(
      'no slots used',
      "{% render 'card' %}{% slot unused %}{{ boom.undefined }}{% endslot %}{% endrender %}",
      partials: { 'card' => 'no slots used' },
    )
  end

  # ------------------------------------------------- lazy evaluation / reads

  def test_unused_default_content_is_not_evaluated
    drop = SlotReadTrackingDrop.new('secret' => 'SECRET')
    assert_template_result(
      'provided',
      "{% render 'card' %}{% slot actions %}provided{% endslot %}{% endrender %}",
      { 'tracker' => drop },
      partials: { 'card' => "{% slot actions %}{{ tracker.secret }}{% endslot %}" },
    )
    assert_equal(0, drop.reads['secret'])
  end

  def test_default_content_is_evaluated_when_used
    drop = SlotReadTrackingDrop.new('secret' => 'SECRET')
    assert_template_result(
      'SECRET',
      "{% render 'card' %}",
      { 'tracker' => drop },
      partials: { 'card' => "{% slot actions %}{{ tracker.secret }}{% endslot %}" },
    )
    assert_equal(1, drop.reads['secret'])
  end

  def test_unused_supplied_slot_is_not_evaluated
    # if it were evaluated, referencing an undefined method of nil would error
    assert_template_result(
      'card body',
      "{% render 'card' %}{% slot actions %}{{ nope.missing }}{% endslot %}{% endrender %}",
      partials: { 'card' => 'card body' },
    )
  end

  # ------------------------------------------------------------ scope rules

  def test_slot_reads_caller_local_variables
    assert_template_result(
      'slot=CALLER',
      "{% assign caller_var = 'CALLER' %}{% render 'card' %}{% slot actions %}slot={{ caller_var }}{% endslot %}{% endrender %}",
      partials: { 'card' => "{% slot actions %}default{% endslot %}" },
    )
  end

  def test_slot_reads_render_arguments
    assert_template_result(
      'slot=arg-value',
      "{% render 'card', title: 'arg-value' %}{% slot actions %}slot={{ title }}{% endslot %}{% endrender %}",
      partials: { 'card' => "{% slot actions %}default{% endslot %}" },
    )
  end

  def test_partial_variables_do_not_leak_into_a_slot
    # `secret` is assigned inside the snippet; the slot must not see it
    assert_template_result(
      'slot=',
      "{% render 'card' %}{% slot actions %}slot={{ secret }}{% endslot %}{% endrender %}",
      partials: { 'card' => "{% assign secret = 'hidden' %}{% slot actions %}default{% endslot %}" },
    )
  end

  def test_slot_assignments_do_not_leak_back_to_the_caller
    assert_template_result(
      'slot-assigned|after=',
      "{% render 'card' %}{% slot actions %}slot-{% assign leaked = 'assigned' %}{{ leaked }}{% endslot %}{% endrender %}after={{ leaked }}",
      partials: { 'card' => "{% slot actions %}default{% endslot %}|" },
    )
  end

  def test_slot_assignment_does_not_overwrite_caller_assignment
    template =
      "{% assign name = 'outer' %}" \
      "{% render 'card' %}{% slot actions %}{% assign name = 'inner' %}{{ name }}{% endslot %}{% endrender %}" \
      "|{{ name }}"
    assert_template_result('inner|outer', template, partials: { 'card' => "{% slot actions %}default{% endslot %}" })
  end

  def test_a_slot_can_be_used_multiple_times_with_independent_bindings
    assert_template_result(
      '1|1',
      "{% render 'card' %}{% slot counter %}{% assign n = n | default: 0 | plus: 1 %}{{ n }}{% endslot %}{% endrender %}",
      partials: { 'card' => "{% slot counter %}0{% endslot %}|{% slot counter %}0{% endslot %}" },
    )
  end

  def test_default_content_uses_have_independent_bindings
    # The assignment inside the first use must not be visible in the second
    # use, even though both start from the same snippet-level variables.
    assert_template_result(
      '1|1',
      "{% render 'card' %}",
      partials: {
        'card' => "{% assign n = 0 %}" \
                  "{% slot counter %}{% assign n = n | plus: 1 %}{{ n }}{% endslot %}" \
                  "|{% slot counter %}{% assign n = n | plus: 1 %}{{ n }}{% endslot %}",
      },
    )
  end

  # ------------------------------------------------------------- render for

  def test_render_for_binds_each_item_to_the_slot_independently
    assert_template_result(
      '[a:act-a][b:act-b]',
      "{% render 'card' for items as item %}{% slot actions %}act-{{ item }}{% endslot %}{% endrender %}",
      { 'items' => %w[a b] },
      partials: { 'card' => "[{{ item }}:{% slot actions %}{{ item }}{% endslot %}]" },
    )
  end

  def test_render_for_slot_bindings_do_not_leak_between_iterations
    assert_template_result(
      '[a:1][b:1][c:1]',
      "{% render 'card' for items as item %}{% slot actions %}{% assign n = n | default: 0 | plus: 1 %}{{ n }}{% endslot %}{% endrender %}",
      { 'items' => %w[a b c] },
      partials: { 'card' => "[{{ item }}:{% slot actions %}{{ item }}{% endslot %}]" },
    )
  end

  def test_render_for_slot_still_reads_caller_locals
    assert_template_result(
      '[a:me-a][b:me-b]',
      "{% assign who = 'me' %}{% render 'card' for items as item %}" \
      "{% slot actions %}{{ who }}-{{ item }}{% endslot %}{% endrender %}",
      { 'items' => %w[a b] },
      partials: { 'card' => "[{{ item }}:{% slot actions %}{{ item }}{% endslot %}]" },
    )
  end

  # --------------------------------------------------------------- nesting

  def test_nested_partial_renders_its_own_slot_default
    assert_template_result(
      'OUTER-INNER[inner-default]-END',
      "{% render 'outer' %}",
      partials: {
        'outer' => "OUTER-{% render 'inner' %}-END",
        'inner' => "INNER[{% slot actions %}inner-default{% endslot %}]",
      },
    )
  end

  def test_slots_supplied_to_an_outer_render_do_not_propagate_to_a_nested_render
    assert_template_result(
      'OUTER-INNER[inner-default]-END',
      "{% render 'outer' %}{% slot actions %}outer-slot{% endslot %}{% endrender %}",
      partials: {
        'outer' => "OUTER-{% render 'inner' %}-END",
        'inner' => "INNER[{% slot actions %}inner-default{% endslot %}]",
      },
    )
  end

  def test_slot_content_can_itself_render_a_partial
    assert_template_result(
      'card: ->button',
      "{% render 'card' %}{% slot actions %}{% render 'button' %}{% endslot %}{% endrender %}",
      partials: {
        'card'   => "card: {% slot actions %}default{% endslot %}",
        'button' => '->button',
      },
    )
  end

  def test_include_is_disabled_inside_slot_content
    assert_template_result(
      'Liquid error (line 1): include usage is not allowed in this context',
      "{% render 'card' %}{% slot actions %}{% include 'foo' %}{% endslot %}{% endrender %}",
      render_errors: true,
      partials: {
        'card' => "{% slot actions %}default{% endslot %}",
        'foo'  => 'bar',
      },
    )
  end

  # --------------------------------------------- end-to-end email card demo
  #
  # Two emails share the same title, but the caller passes a different action
  # area to each card through a nested snippet + a `render for` loop.

  EMAIL_PARTIALS = {
    'email_card' =>
      "CARD(title={{ card.title }}): " \
      "{% render 'email_card_section', heading: card.title %}" \
      " [actions: {% slot actions %}default action{% endslot %}]",
    'email_card_section' =>
      "section<{{ heading }}>{% slot actions %}section default{% endslot %}</section>",
  }.freeze

  def test_two_cards_same_title_different_action_areas_with_nesting_and_loop
    # Both cards share the same title; the loop binds a different `action` on
    # every iteration, so each card's action area is rendered independently.
    template =
      "{% render 'email_card' for emails as card %}" \
      "{% slot actions %}{{ card.action }} ({{ forloop.index }}){% endslot %}" \
      "{% endrender %}"

    emails = [
      { 'title' => 'Weekly Newsletter', 'action' => 'Subscribe' },
      { 'title' => 'Weekly Newsletter', 'action' => 'Unsubscribe' },
    ]

    assert_template_result(
      "CARD(title=Weekly Newsletter): section<Weekly Newsletter>section default</section> [actions: Subscribe (1)]" \
        "CARD(title=Weekly Newsletter): section<Weekly Newsletter>section default</section> [actions: Unsubscribe (2)]",
      template,
      { 'emails' => emails },
      partials: EMAIL_PARTIALS,
    )
  end

  def test_email_card_falls_back_to_default_action_area
    assert_template_result(
      "CARD(title=Hello): section<Hello>section default</section> [actions: default action]",
      "{% render 'email_card' with card %}",
      { 'card' => { 'title' => 'Hello' } },
      partials: EMAIL_PARTIALS,
    )
  end

  def test_empty_render_body_is_not_a_block_form
    # With no slot block inside, `endrender` is an unknown tag rather than a
    # block delimiter (block form requires at least one slot).
    assert_syntax_error("{% render 'card' %}{% endrender %}")
  end

  def test_slot_without_a_name_is_a_syntax_error
    with_error_modes(:lax, :strict, :strict2, :warn) do
      assert_syntax_error("{% slot %}{% endslot %}")
      assert_syntax_error("{% slot '' %}{% endslot %}")
    end
  end

  def test_slot_with_extra_markup_is_a_syntax_error_in_strict2
    with_error_modes(:strict2) do
      assert_syntax_error("{% slot a b %}{% endslot %}")
    end
  end
end
