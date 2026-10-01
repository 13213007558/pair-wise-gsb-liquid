# frozen_string_literal: true

require 'test_helper'

class DropReadSnapshotTest < Minitest::Test
  # Simulates a drop backed by an external data source whose values can
  # change between two reads within a single render.
  class ChangingReportDrop < Liquid::Drop
    attr_reader :reads

    def initialize
      @reads = Hash.new(0)
    end

    def title
      @reads['title'] += 1
      'Monthly report'
    end

    def amount
      @reads['amount'] += 1
      @reads['amount'] * 100
    end
  end

  # Records every read and serves values from a backend hash; missing
  # keys read as nil, like a missing method on a drop.
  class CountingDrop < Liquid::Drop
    attr_reader :calls

    def initialize(backend = {})
      @backend = backend
      @calls   = Hash.new(0)
    end

    def liquid_method_missing(key)
      @calls[key] += 1
      @backend[key]
    end
  end

  # Returns a brand new child drop on every read.
  class ChildFactoryDrop < Liquid::Drop
    attr_reader :child_reads

    def initialize
      @child_reads = 0
    end

    def child
      @child_reads += 1
      ChildDrop.new(@child_reads)
    end
  end

  class ChildDrop < Liquid::Drop
    def initialize(id)
      @id = id
    end

    def amount
      @id * 100
    end
  end

  class ListDrop < Liquid::Drop
    def initialize(items)
      @items = items
    end

    def items
      @items
    end
  end

  class BoobyTrapDrop < Liquid::Drop
    def amount
      100
    end

    def unaccessed
      raise 'must never be invoked'
    end
  end

  def render_with_snapshot(template_source, assigns)
    Liquid::Template.parse(template_source).render(assigns, drop_read_snapshot: true)
  end

  def test_repeated_read_of_same_path_returns_first_result
    drop = ChangingReportDrop.new

    output = render_with_snapshot(
      '{{ report.title }}: {{ report.amount }} / {{ report.amount }}',
      'report' => drop,
    )

    assert_equal('Monthly report: 100 / 100', output)
    assert_equal(1, drop.reads['amount'])
    assert_equal(1, drop.reads['title'])
  end

  def test_snapshot_is_disabled_by_default
    drop = ChangingReportDrop.new

    output = Liquid::Template.parse('{{ report.amount }} / {{ report.amount }}').render('report' => drop)

    assert_equal('100 / 200', output)
    assert_equal(2, drop.reads['amount'])
  end

  def test_nil_results_are_cached
    drop = CountingDrop.new('nothing' => nil)

    output = render_with_snapshot('{{ report.nothing }}|{{ report.nothing }}', 'report' => drop)

    assert_equal('|', output)
    assert_equal(1, drop.calls['nothing'])
  end

  def test_missing_results_are_cached
    drop = CountingDrop.new

    output = render_with_snapshot('{{ report.ghost }}|{{ report.ghost }}', 'report' => drop)

    assert_equal('|', output)
    assert_equal(1, drop.calls['ghost'])
  end

  def test_dynamic_indices_are_distinct_paths
    drop = CountingDrop.new(1 => 'one', 2 => 'two')

    output = render_with_snapshot(
      '{% assign i = 1 %}{{ report[i] }}-{{ report[2] }}-{{ report[i] }}',
      'report' => drop,
    )

    assert_equal('one-two-one', output)
    assert_equal(1, drop.calls[1])
    assert_equal(1, drop.calls[2])
  end

  def test_drop_returning_new_child_objects_is_consistent
    drop = ChildFactoryDrop.new

    output = render_with_snapshot('{{ report.child.amount }}|{{ report.child.amount }}', 'report' => drop)

    assert_equal('100|100', output)
    assert_equal(1, drop.child_reads)
  end

  def test_drop_returning_new_child_objects_without_snapshot
    drop = ChildFactoryDrop.new

    output = Liquid::Template.parse('{{ report.child.amount }}|{{ report.child.amount }}').render('report' => drop)

    assert_equal('100|200', output)
    assert_equal(2, drop.child_reads)
  end

  def test_untaken_conditional_branch_is_never_read
    drop = CountingDrop.new('show' => false, 'secret' => 'hidden')

    output = render_with_snapshot(
      '{% if report.show %}{{ report.secret }}{% endif %}',
      'report' => drop,
    )

    assert_equal('', output)
    assert_equal(1, drop.calls['show'])
    assert_equal(0, drop.calls['secret'])
  end

  def test_unaccessed_properties_are_never_enumerated
    output = render_with_snapshot('{{ report.amount }}', 'report' => BoobyTrapDrop.new)

    assert_equal('100', output)
  end

  def test_nested_render_shares_the_snapshot
    environment = Liquid::Environment.build(
      file_system: StubFileSystem.new('snippet' => '{{ report.amount }}'),
    )
    template = Liquid::Template.parse(
      '{{ report.amount }}|{% render "snippet" %}|{{ report.amount }}',
      environment: environment,
    )
    drop = ChangingReportDrop.new
    context = Liquid::Context.build(
      static_environments: { 'report' => drop },
      environment: environment,
    )
    context.drop_read_snapshot = true

    assert_equal('100|100|100', template.render(context))
    assert_equal(1, drop.reads['amount'])
  end

  def test_nested_render_without_snapshot_rereads
    environment = Liquid::Environment.build(
      file_system: StubFileSystem.new('snippet' => '{{ report.amount }}'),
    )
    template = Liquid::Template.parse(
      '{{ report.amount }}|{% render "snippet" %}|{{ report.amount }}',
      environment: environment,
    )
    drop = ChangingReportDrop.new
    context = Liquid::Context.build(
      static_environments: { 'report' => drop },
      environment: environment,
    )

    assert_equal('100|200|300', template.render(context))
    assert_equal(3, drop.reads['amount'])
  end

  def test_each_render_starts_a_fresh_snapshot
    template = Liquid::Template.parse('{{ report.amount }}')
    drop = ChangingReportDrop.new

    assert_equal('100', template.render({ 'report' => drop }, drop_read_snapshot: true))
    assert_equal('200', template.render({ 'report' => drop }, drop_read_snapshot: true))
    assert_equal(2, drop.reads['amount'])
  end

  def test_reused_context_gets_a_fresh_snapshot_per_render
    template = Liquid::Template.parse('{{ report.amount }}')
    drop = ChangingReportDrop.new
    context = Liquid::Context.new([{ 'report' => drop }])

    assert_equal('100', template.render(context, drop_read_snapshot: true))
    assert_equal('200', template.render(context, drop_read_snapshot: true))
    assert_equal(2, drop.reads['amount'])
  end

  def test_for_loop_variables_are_rebound_each_iteration
    first  = CountingDrop.new('price' => 1)
    second = CountingDrop.new('price' => 2)
    drop   = ListDrop.new([first, second])

    output = render_with_snapshot(
      '{% for p in report.items %}{{ p.price }}{{ p.price }};{% endfor %}',
      'report' => drop,
    )

    assert_equal('11;22;', output)
    assert_equal(1, first.calls['price'])
    assert_equal(1, second.calls['price'])
  end

  def test_forloop_state_is_not_cached
    template = Liquid::Template.parse('{% for i in (1..3) %}{{ forloop.index }}{% endfor %}')

    assert_equal('123', template.render(nil, drop_read_snapshot: true))
  end

  def test_tablerowloop_state_is_not_cached
    template = Liquid::Template.parse(
      '{% tablerow i in (1..3) cols:3 %}{{ tablerowloop.index }}{% endtablerow %}',
    )

    assert_equal(
      "<tr class=\"row1\">\n<td class=\"col1\">1</td><td class=\"col2\">2</td><td class=\"col3\">3</td></tr>\n",
      template.render(nil, drop_read_snapshot: true),
    )
  end

  def test_self_lookups_are_not_cached
    template = Liquid::Template.parse("{% assign x = 'a' %}{{ self.x }}{% assign x = 'b' %}{{ self.x }}")

    assert_equal('ab', template.render(nil, drop_read_snapshot: true))
  end

  def test_aliased_root_names_are_distinct_paths
    drop = ChangingReportDrop.new

    output = render_with_snapshot(
      '{% assign r = report %}{{ r.amount }}|{{ report.amount }}',
      'report' => drop,
    )

    assert_equal('100|200', output)
    assert_equal(2, drop.reads['amount'])
  end
end
