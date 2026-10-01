# frozen_string_literal: true

require 'test_helper'

class HTMLSafeTrackerUnitTest < Minitest::Test
  def new_tracker
    Liquid::HTMLSafe::Tracker.new
  end

  def test_starts_in_text_context
    assert_equal(:text, new_tracker.context.type)
  end

  def test_tracks_double_quoted_attribute
    tracker = new_tracker
    tracker.track('<div class="')
    context = tracker.context
    assert_equal(:attribute, context.type)
    assert_equal('class', context.attribute_name)
    assert_equal(:double, context.quote)
  end

  def test_tracks_single_quoted_and_unquoted_attributes
    tracker = new_tracker
    tracker.track("<a href='")
    assert_equal(:single, tracker.context.quote)

    tracker = new_tracker
    tracker.track('<a href=')
    assert_equal(:unquoted, tracker.context.quote)
  end

  def test_attribute_names_are_case_insensitive
    tracker = new_tracker
    tracker.track('<div OnClick="')
    assert_equal('onclick', tracker.context.attribute_name)
  end

  def test_context_survives_tokens_split_mid_tag
    tracker = new_tracker
    tracker.track('<di')
    tracker.track('v cla')
    tracker.track('ss="va')
    assert_equal(:attribute, tracker.context.type)
    assert_equal('class', tracker.context.attribute_name)
    tracker.track('l">')
    assert_equal(:text, tracker.context.type)
  end

  def test_lt_followed_by_text_is_literal
    tracker = new_tracker
    tracker.track('a < b')
    assert_equal(:text, tracker.context.type)
  end

  def test_script_content_is_rawtext_until_end_tag
    tracker = new_tracker
    tracker.track('<script>')
    assert_equal(:rawtext, tracker.context.type)
    tracker.track('var a = "</div>";')
    assert_equal(:rawtext, tracker.context.type)
    tracker.track('</script>')
    assert_equal(:text, tracker.context.type)
  end

  def test_script_end_tag_split_across_tokens
    tracker = new_tracker
    tracker.track('<script>x</scr')
    assert_equal(:rawtext, tracker.context.type)
    tracker.track('ipt>')
    assert_equal(:text, tracker.context.type)
  end

  def test_rawtext_tag_names_are_case_insensitive
    tracker = new_tracker
    tracker.track('<SCRIPT>')
    assert_equal(:rawtext, tracker.context.type)
    tracker.track('</ScRiPt>')
    assert_equal(:text, tracker.context.type)
  end

  def test_self_closing_script_still_enters_rawtext
    tracker = new_tracker
    tracker.track('<script/>')
    assert_equal(:rawtext, tracker.context.type)
  end

  def test_style_is_rawtext
    tracker = new_tracker
    tracker.track('<style>')
    assert_equal(:rawtext, tracker.context.type)
  end

  def test_comment_context
    tracker = new_tracker
    tracker.track('<!--')
    assert_equal(:comment, tracker.context.type)
    tracker.track(' <div> ')
    assert_equal(:comment, tracker.context.type)
    tracker.track('-->')
    assert_equal(:text, tracker.context.type)
  end

  def test_comment_split_across_tokens
    tracker = new_tracker
    tracker.track('<!-')
    tracker.track('- x -')
    assert_equal(:comment, tracker.context.type)
    tracker.track('->')
    assert_equal(:text, tracker.context.type)
  end

  def test_inside_tag_but_outside_attribute_value
    tracker = new_tracker
    tracker.track('<div ')
    assert_equal(:tag, tracker.context.type)
  end

  def test_end_tag_returns_to_text
    tracker = new_tracker
    tracker.track('<div></div>')
    assert_equal(:text, tracker.context.type)
  end

  def test_url_attribute_value_prefix_is_tracked
    tracker = new_tracker
    tracker.track('<a href="https://')
    context = tracker.context
    assert_equal(:attribute, context.type)
    assert_equal('https://', context.value_prefix)
  end

  def test_valueless_attribute
    tracker = new_tracker
    tracker.track('<input disabled>')
    assert_equal(:text, tracker.context.type)
  end

  def test_snapshot_and_restore
    tracker = new_tracker
    tracker.track('<div title="')
    snapshot = tracker.snapshot
    tracker.reset
    tracker.track('<script>')
    assert_equal(:rawtext, tracker.context.type)
    tracker.restore(snapshot)
    context = tracker.context
    assert_equal(:attribute, context.type)
    assert_equal('title', context.attribute_name)
  end
end
