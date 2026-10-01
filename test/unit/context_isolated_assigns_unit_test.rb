# frozen_string_literal: true

require 'test_helper'

class ContextIsolatedAssignsUnitTest < Minitest::Test
  include Liquid

  def context_with(assigns = {})
    Context.build(outer_scope: assigns)
  end

  def test_assignments_inside_the_block_do_not_leak_out
    context = context_with
    context.with_isolated_assigns do
      context['value'] = 42
      assert_equal(42, context['value'])
    end
    assert_nil(context['value'])
  end

  def test_caller_assignments_remain_readable_inside_the_block
    context = context_with('outer' => 'visible')
    context.with_isolated_assigns do
      assert_equal('visible', context['outer'])
    end
  end

  def test_bindings_are_available_inside_the_block
    context = context_with
    context.with_isolated_assigns('item' => 'x') do
      assert_equal('x', context['item'])
    end
    assert_nil(context['item'])
  end

  def test_bindings_override_caller_variables_only_for_the_block
    context = context_with('name' => 'outer')
    context.with_isolated_assigns('name' => 'inner') do
      assert_equal('inner', context['name'])
    end
    assert_equal('outer', context['name'])
  end

  def test_each_block_starts_from_a_fresh_snapshot
    context = context_with('n' => 1)
    context.with_isolated_assigns { context['n'] = 2 }
    context.with_isolated_assigns do
      assert_equal(1, context['n'], 'a previous isolated block must not change the caller scope')
    end
  end

  def test_nested_blocks_restore_the_outer_scope
    context = context_with('name' => 'outer')
    context.with_isolated_assigns('name' => 'middle') do
      context.with_isolated_assigns('name' => 'inner') do
        assert_equal('inner', context['name'])
      end
      assert_equal('middle', context['name'])
    end
    assert_equal('outer', context['name'])
  end
end
