# frozen_string_literal: true

require 'test_helper'

# A drop that counts how many times each property is evaluated and returns a
# value that changes between calls, mimicking an external backend whose data
# changes while a report is being rendered.
class CountingDrop < Liquid::Drop
  class ChildDrop < Liquid::Drop
    def initialize(parent)
      super()
      @parent = parent
    end

    def value
      @parent.count_read("child.value")
    end
  end

  attr_reader :read_counts

  def initialize
    super
    @read_counts = Hash.new(0)
  end

  def amount
    count_read("amount")
  end

  def always_nil
    count_read("always_nil")
    nil
  end

  def child
    count_read("child")
    ChildDrop.new(self)
  end

  def liquid_method_missing(method_name)
    count_read(method_name)
  end

  def count_read(name)
    @read_counts[name] += 1
    @read_counts[name]
  end
end

class DropReadSnapshotTest < Minitest::Test
  include Liquid

  def setup
    @drop = CountingDrop.new
  end

  def test_repeated_reads_within_a_render_return_the_first_value
    template = Template.parse('{{ report.amount }} {{ report.amount }}')

    assert_equal('1 1', template.render!({ 'report' => @drop }, snapshot_drops: true))
    assert_equal(1, @drop.read_counts['amount'])
  end

  def test_without_the_option_each_read_is_reevaluated
    template = Template.parse('{{ report.amount }} {{ report.amount }}')

    assert_equal('1 2', template.render!({ 'report' => @drop }))
    assert_equal(2, @drop.read_counts['amount'])
  end

  def test_each_render_reads_the_drops_again
    template = Template.parse('{{ report.amount }}')

    assert_equal('1', template.render!({ 'report' => @drop }, snapshot_drops: true))
    assert_equal('2', template.render!({ 'report' => @drop }, snapshot_drops: true))
    assert_equal(2, @drop.read_counts['amount'])
  end

  def test_nil_results_are_snapshotted
    template = Template.parse('{{ report.always_nil }}|{{ report.always_nil }}')

    assert_equal('|', template.render!({ 'report' => @drop }, snapshot_drops: true))
    assert_equal(1, @drop.read_counts['always_nil'])
  end

  def test_missing_results_from_method_missing_are_snapshotted
    template = Template.parse('{{ report.unknown }} {{ report.unknown }}')

    assert_equal('1 1', template.render!({ 'report' => @drop }, snapshot_drops: true))
    assert_equal(1, @drop.read_counts['unknown'])
  end

  def test_dynamic_indexes_are_cached_per_concrete_path
    template = Template.parse(
      '{% assign key = "a" %}{{ report[key] }} {{ report[key] }} {{ report.b }}',
    )

    assert_equal('1 1 1', template.render!({ 'report' => @drop }, snapshot_drops: true))
    assert_equal(1, @drop.read_counts['a'])
    assert_equal(1, @drop.read_counts['b'])
  end

  def test_unvisited_properties_are_never_evaluated
    template = Template.parse(
      '{% if true %}{{ report.amount }}{% else %}{{ report.missing_branch }}{% endif %}',
    )

    template.render!({ 'report' => @drop }, snapshot_drops: true)
    assert_equal(1, @drop.read_counts['amount'])
    refute_includes(@drop.read_counts, 'missing_branch')
  end

  def test_nested_render_shares_the_snapshot
    partials = { 'snippet' => '{{ report.amount }}' }
    file_system = StubFileSystem.new(partials)
    environment = Liquid::Environment.build(file_system: file_system)
    template = Template.parse(
      '{{ report.amount }} {% render "snippet" %}',
      environment: environment,
    )
    registers = Liquid::Registers.new(file_system: file_system)
    context = Liquid::Context.build(
      static_environments: { 'report' => @drop },
      registers: registers,
      environment: environment,
    )

    assert_equal('1 1', template.render!(context, snapshot_drops: true))
    assert_equal(1, @drop.read_counts['amount'])
  end

  def test_nested_render_reevaluates_on_the_next_render
    partials = { 'snippet' => '{{ report.amount }}' }
    file_system = StubFileSystem.new(partials)
    environment = Liquid::Environment.build(file_system: file_system)
    template = Template.parse(
      '{{ report.amount }} {% render "snippet" %}',
      environment: environment,
    )
    build_context = lambda {
      Liquid::Context.build(
        static_environments: { 'report' => @drop },
        registers: Liquid::Registers.new(file_system: file_system),
        environment: environment,
      )
    }

    assert_equal('1 1', template.render!(build_context.call, snapshot_drops: true))
    assert_equal('2 2', template.render!(build_context.call, snapshot_drops: true))
    assert_equal(2, @drop.read_counts['amount'])
  end

  def test_drop_returning_new_child_objects_is_consistent_within_a_render
    template = Template.parse('{{ report.child.value }} {{ report.child.value }}')

    assert_equal('1 1', template.render!({ 'report' => @drop }, snapshot_drops: true))
    assert_equal(1, @drop.read_counts['child'])
    assert_equal(1, @drop.read_counts['child.value'])
  end

  def test_child_objects_are_refetched_on_the_next_render
    template = Template.parse('{{ report.child.value }}')

    assert_equal('1', template.render!({ 'report' => @drop }, snapshot_drops: true))
    assert_equal('2', template.render!({ 'report' => @drop }, snapshot_drops: true))
    assert_equal(2, @drop.read_counts['child'])
  end

  def test_distinct_drop_instances_have_independent_snapshots
    other = CountingDrop.new
    template = Template.parse('{{ first.amount }} {{ second.amount }}')

    assert_equal(
      '1 1',
      template.render!({ 'first' => @drop, 'second' => other }, snapshot_drops: true),
    )
    assert_equal(1, @drop.read_counts['amount'])
    assert_equal(1, other.read_counts['amount'])
  end

  def test_internal_mutable_drop_state_is_not_duplicated
    mutable = Class.new(Liquid::Drop) do
      def initialize
        super
        @touched = 0
      end

      def touch
        @touched += 1
        @touched
      end
    end.new
    template = Template.parse('{{ report.touch }} {{ report.touch }}')

    assert_equal('1 1', template.render!({ 'report' => mutable }, snapshot_drops: true))
    assert_equal(1, mutable.instance_variable_get(:@touched))
  end
end
