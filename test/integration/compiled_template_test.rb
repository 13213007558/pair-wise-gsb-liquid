# frozen_string_literal: true

require 'test_helper'
require 'json'
require 'open3'
require 'tmpdir'

class CompiledTemplateTest < Minitest::Test
  ROUNDTRIP_HELPER = File.expand_path('../../fixtures/compiled_template_roundtrip_helper.rb', __FILE__)
  ROUNDTRIP_FIXTURE = File.expand_path('../../fixtures/compiled_template_roundtrip.rb', __FILE__)

  def test_roundtrip_normal_undefined_and_filter_results_in_a_new_process
    require ROUNDTRIP_HELPER
    original = CompiledTemplateRoundtripHelper.parse
    expected = CompiledTemplateRoundtripHelper.results(original)
    payload = original.export_compiled

    Dir.mktmpdir do |directory|
      path = File.join(directory, 'compiled.json')
      File.write(path, payload)
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, ROUNDTRIP_FIXTURE, path)
      assert_predicate(status, :success?, stderr)
      assert_equal(expected, JSON.parse(stdout))
    end
  end

  def test_roundtrips_control_flow_render_and_builtin_expressions
    partials = {
      'item' => '{{ item.name }}{% if item.active %}*{% endif %}',
      'nested' => '{% render "item", item: outer %}',
    }
    file_system = StubFileSystem.new(partials)
    environment = Liquid::Environment.build(file_system: file_system)
    source = <<~LIQUID
      {% assign greeting = "hello" %}
      {{ greeting | upcase }}
      {% for item in items limit: 2 %}{% render 'item' %} {% endfor %}
      {% render 'nested', outer: items.first %}
      {% unless false %}unless{% endunless %}
      {% case 2 %}{% when 1, 2 %}case{% endcase %}
      {% for value in (1..2) %}{{ value }}{% endfor %}
    LIQUID

    original = Liquid::Template.parse(source, environment: environment)
    loaded = Liquid::Template.load_compiled(original.export_compiled, environment: environment)
    assigns = { 'items' => [{ 'name' => 'a', 'active' => true }, { 'name' => 'b', 'active' => false }] }
    registers = { file_system: file_system }

    assert_equal(
      original.render!(assigns.dup, registers: registers),
      loaded.render!(assigns.dup, registers: registers),
    )
  end

  def test_roundtrips_include_dependencies_when_explicitly_requested
    partials = { 'shared' => 'shared {{ value }}' }
    file_system = StubFileSystem.new(partials)
    environment = Liquid::Environment.build(file_system: file_system)
    original = Liquid::Template.parse("{% include 'shared' %}", environment: environment)
    loaded = Liquid::Template.load_compiled(
      original.export_compiled(file_system: file_system, include_dependencies: true),
      environment: environment,
    )

    assert_equal('shared value', loaded.render!({ 'value' => 'value' }, registers: { file_system: file_system }))
  end

  def test_roundtrips_all_core_tags_expressions_and_strict2_parsing
    partials = {
      'detail' => '{% increment detail_counter %} {{ detail_name }} {{ detail.size }} {{ detail.first.name }}',
    }
    file_system = StubFileSystem.new(partials)
    environment = Liquid::Environment.build(file_system: file_system, error_mode: :strict2)
    source = <<~LIQUID
      {% raw %}{{ ignored }}{% endraw %}
      {% echo title | upcase %}
      {% if title == blank %}blank{% elsif title contains 'x' %}x{% endif %}
      {% unless title == 'nope' %}ok{% endunless %}
      {% case title %}{% when 'abc', 'xyz' %}match{% endcase %}
      {% assign upper = title | upcase %}{{ upper[0] }}
      {% capture captured %}[{{ nested.value }}]{% endcapture %}{{ captured }}
      {% increment root_counter %}{% increment root_counter %}{% decrement root_counter %}
      {% tablerow item in rows cols: 1 %}{{ item }}{% endtablerow %}
      {% for item in (1..3) %}{% if item == 2 %}{% continue %}{% endif %}{{ item }}{% if item == 3 %}{% break %}{% endif %}{% endfor %}
      {% cycle 'one', 'two' %} {% cycle 'one', 'two' %}
      {% render 'detail', detail: items.first, detail_name: dynamic['key'], items: items %}
    LIQUID
    assigns = {
      'title' => 'abc',
      'nested' => { 'value' => 'v' },
      'rows' => %w[a b],
      'dynamic' => { 'key' => 'named' },
      'items' => [{ 'name' => 'first' }, { 'name' => 'second' }],
    }
    original = Liquid::Template.parse(source, environment: environment)
    loaded = Liquid::Template.load_compiled(original.export_compiled, environment: environment)
    registers = { file_system: file_system }

    assert_equal(
      original.render!(assigns.dup, registers: registers),
      loaded.render!(assigns.dup, registers: registers),
    )
  end

  def test_uses_explicit_filter_and_custom_tag_registration_names
    filter_module = Module.new do
      def compiled_reverse(value)
        value.to_s.reverse
      end
    end
    custom_tag = Class.new(Liquid::Tag) do
      def render_to_output_buffer(_context, output)
        output << 'tag-output'
        output
      end
    end
    environment = Liquid::Environment.build do |env|
      env.register_filter(filter_module)
      env.register_tag('compiled_tag', custom_tag)
    end
    original = Liquid::Template.parse('{{ "abc" | compiled_reverse }} {% compiled_tag %}', environment: environment)
    loaded = Liquid::Template.load_compiled(original.export_compiled, environment: environment)

    assert_equal('cba tag-output', loaded.render!)
  end

  def test_standard_tag_class_can_be_registered_with_an_explicit_name
    environment = Liquid::Environment.build do |env|
      env.register_tag('notice', Liquid::Echo)
    end
    original = Liquid::Template.parse('{% notice "hello" | upcase %}', environment: environment)
    loaded = Liquid::Template.load_compiled(original.export_compiled, environment: environment)

    assert_equal('HELLO', loaded.render!)
    assert_equal('notice', loaded.root.nodelist.last.tag_name)
  end

  def test_custom_tag_payload_is_rebound_without_ruby_objects
    custom_tag = Class.new(Liquid::Tag) do
      def compiled_tag_payload
        { 'label' => @markup.strip }
      end

      def render_to_output_buffer(_context, output)
        output << compiled_tag_data.fetch('payload').fetch('label')
        output
      end
    end
    environment = Liquid::Environment.build do |env|
      env.register_tag('payload_tag', custom_tag)
    end
    original = Liquid::Template.parse('{% payload_tag hello %}', environment: environment)
    loaded = Liquid::Template.load_compiled(original.export_compiled, environment: environment)

    assert_equal('hello', loaded.render!)
    assert_includes(original.export_compiled, '"format":"liquid-template"')
    refute_includes(original.export_compiled, '\x04\b')
  end

  def test_load_rejects_unsupported_version_and_unknown_nodes_with_template_names
    template = Liquid::Template.parse('{% if true %}yes{% endif %}')
    payload = JSON.parse(template.export_compiled)
    payload['version'] = 999
    error = assert_raises(Liquid::CompiledTemplateError) { Liquid::Template.load_compiled(JSON.generate(payload)) }
    assert_match('unsupported compiled template version', error.message)

    payload = JSON.parse(template.export_compiled)
    payload['templates']['__root__']['root']['body']['nodes'].first['type'] = 'unexpected'
    error = assert_raises(Liquid::CompiledTemplateError) { Liquid::Template.load_compiled(JSON.generate(payload)) }
    assert_includes(error.message, 'in "__root__"')
  end

  def test_load_reports_missing_tag_filter_and_render_dependency
    custom_tag = Class.new(Liquid::Tag) do
      def render_to_output_buffer(_context, output)
        output << 'custom'
        output
      end
    end
    filter_module = Module.new
    filter_module.define_method(:filter_name) { |value| value }
    source_environment = Liquid::Environment.build do |env|
      env.register_tag('custom_tag', custom_tag)
      env.register_filter(filter_module)
    end
    payload = Liquid::Template.parse('{{ value | filter_name }} {% custom_tag %}', environment: source_environment).export_compiled

    error = assert_raises(Liquid::CompiledTemplateError) { Liquid::Template.load_compiled(payload) }
    assert_includes(error.message, 'missing registered filter "filter_name"')
    error = assert_raises(Liquid::CompiledTemplateError) { Liquid::Template.load_compiled(payload, validate_filters: false) }
    assert_includes(error.message, 'missing registered tag "custom_tag"')

    file_system = StubFileSystem.new('partial' => 'partial')
    environment = Liquid::Environment.build(file_system: file_system)
    original = Liquid::Template.parse("{% render 'partial' %}", environment: environment)
    payload = original.export_compiled(partials: {})
    error = assert_raises(Liquid::CompiledTemplateError) { Liquid::Template.load_compiled(payload, environment: environment) }
    assert_includes(error.message, 'missing render dependency "partial"')
  end

  def test_load_enforces_resource_limits
    payload = Liquid::Template.parse('{{ value }}').export_compiled

    assert_raises(Liquid::CompiledTemplateError) { Liquid::Template.load_compiled(payload, limits: { bytes: 1 }) }
    assert_raises(Liquid::CompiledTemplateError) { Liquid::Template.load_compiled(payload, limits: { depth: 0 }) }
  end

  def test_load_rejects_malformed_references_and_non_primitive_payloads
    file_system = StubFileSystem.new('partial' => 'ok')
    environment = Liquid::Environment.build(file_system: file_system)
    original = Liquid::Template.parse("{% render 'partial' %}", environment: environment)
    payload = JSON.parse(original.export_compiled)
    payload['templates'].delete('partial')
    error = assert_raises(Liquid::CompiledTemplateError) do
      Liquid::Template.load_compiled(JSON.generate(payload), environment: environment)
    end
    assert_includes(error.message, 'missing render dependency')

    custom_tag = Class.new(Liquid::Tag) do
      def compiled_tag_payload
        { 'object' => Object.new }
      end

      def render_to_output_buffer(_context, output)
        output
      end
    end
    custom_environment = Liquid::Environment.build do |env|
      env.register_tag('bad_payload', custom_tag)
    end
    original = Liquid::Template.parse('{% bad_payload %}', environment: custom_environment)
    error = assert_raises(Liquid::CompiledTemplateError) do
      Liquid::Template.load_compiled(original.export_compiled, environment: custom_environment)
    end
    assert_includes(error.message, 'unsupported Object')
  end
end
