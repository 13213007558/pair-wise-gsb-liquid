# frozen_string_literal: true

require 'test_helper'
require 'open3'
require 'json'

class CompiledTemplateTest < Minitest::Test
  include Liquid

  module ExplodeFilter
    def explode(value)
      raise "boom for #{value}"
    end
  end

  class RegisteredTag < Tag
    def render(context)
      "tag #{context['tag_input']}"
    end
  end

  def test_round_trip_in_new_ruby_process
    environment = build_environment
    template = Liquid::Template.parse(source, environment: environment, line_numbers: true, error_mode: :strict2)
    template.name = 'products'
    payload = template.export_compiled
    child_payload = run_child_process(payload)

    assert_equal('ok', child_payload.fetch('status'))
    cases.each do |name, input|
      assert_equal(case_result(template, input), child_payload.fetch(name), name)
    end
  end

  def test_custom_leaf_tag_round_trip
    tag_class = Class.new(Tag) do
      def render(_context)
        'custom'
      end
    end
    environment = Environment.new
    environment.register_tag('custom', tag_class)
    environment.freeze
    template = Template.parse('{% custom %}', environment: environment)

    loaded = CompiledTemplate.load(template.export_compiled, environment: environment)

    assert_equal('custom', loaded.render!)
  end

  def test_no_marshal_or_eval
    source_text = File.read(File.expand_path('../../lib/liquid/compiled_template.rb', __dir__))
    Dir[File.expand_path('../../lib/liquid/compiled_template/*.rb', __dir__)].each do |path|
      source_text << File.read(path)
    end

    refute_match(/\bMarshal\b/, source_text)
    refute_match(/\beval\b/, source_text)
  end

  def test_rejects_unsupported_version
    assert_compiled_error(/unsupported version/) do |payload|
      payload['version'] = 2
    end
  end

  def test_rejects_unknown_node_type
    error = assert_raises(CompiledTemplateError) do
      load_mutated_payload do |payload|
        payload['template']['root']['body']['nodes'][0]['t'] = 'evil'
      end
    end
    assert_equal('products', error.template_name)
    assert_match(/unknown node type/, error.message)
  end

  def test_rejects_missing_render_dependency
    error = assert_raises(CompiledTemplateError) do
      load_mutated_payload do |payload|
        payload['partials'].delete('snippet')
      end
    end
    assert_equal('products', error.template_name)
    assert_match(%r{missing render dependency "snippet"}, error.message)
  end

  def test_missing_filter_error_identifies_template
    error = assert_raises(UndefinedFilter) do
      load_mutated_payload(environment: Liquid::Environment.build) do |payload|
        payload['filters'] = ['never_registered']
        payload['partials'] = {}
        payload['template']['references']['render'] = []
      end
    end
    assert_equal('products', error.template_name)
    assert_match(/never_registered/, error.message)
  end

  def test_missing_custom_tag_error_identifies_template
    error = assert_raises(CompiledTemplateError) do
      load_mutated_payload(environment: Liquid::Environment.build) do |payload|
        payload['filters'] = []
        payload['tags'] = ['never_registered']
        payload['partials']['snippet']['root']['body']['nodes'][-1] = {
          't' => 'custom_tag',
          'tag' => 'never_registered',
          'markup' => '',
          'line' => 1,
          'blank' => false,
        }
      end
    end
    assert_equal('snippet', error.template_name)
    assert_equal(1, error.line_number)
    assert_match(/never_registered/, error.message)
  end

  def test_rejects_node_count_above_limit
    error = assert_raises(CompiledTemplateError) do
      CompiledTemplate.load(package_json, environment: build_environment, max_nodes: 10)
    end
    assert_match(/node count exceeds/, error.message)
  end

  def test_rejects_nesting_above_limit
    error = assert_raises(CompiledTemplateError) do
      CompiledTemplate.load(package_json, environment: build_environment, max_depth: 1)
    end
    assert_match(/nesting depth exceeds/, error.message)
  end

  private

  def build_environment
    values = { 'snippet' => "snippet {{ tag_input | upcase }} {% registered %}" }
    file_system = Object.new
    file_system.define_singleton_method(:read_template_file) { |name| values.fetch(name) }

    environment = Environment.new
    environment.file_system = file_system
    environment.error_mode = :strict2
    environment.register_filter(ExplodeFilter)
    environment.register_tag('registered', RegisteredTag)
    environment.freeze
    environment
  end

  def source
    <<~LIQUID
      {% if enabled %}
        {{ items.size }} {{ title | default: "fallback" | explode }}
        {% for item in items reversed limit:2 %}
          {{ item.name }}-{{ forloop.index }}
        {% endfor %}
        {% render 'snippet', tag_input: title %}
      {% endif %}
    LIQUID
  end

  def cases
    {
      'normal' => {
        'enabled' => true,
        'title' => 'product',
        'items' => [{ 'name' => 'one' }, { 'name' => 'two' }],
      },
      'undefined' => {},
      'filter_exception' => {
        'enabled' => true,
        'title' => 'widget',
        'items' => [],
      },
    }
  end

  def case_result(template, input)
    {
      'ok' => true,
      'output' => template.render!(input, strict_variables: true),
    }
  rescue Liquid::Error, ::StandardError => e
    {
      'ok' => false,
      'class' => e.class.name,
      'message' => e.message,
      'line' => (e.line_number if e.respond_to?(:line_number)),
      'template' => (e.template_name if e.respond_to?(:template_name)),
    }
  end

  def package_payload
    @package_payload ||= begin
      template = Liquid::Template.parse(
        source,
        environment: build_environment,
        line_numbers: true,
        error_mode: :strict2,
      )
      template.name = 'products'
      JSON.parse(template.export_compiled)
    end
  end

  def package_json
    JSON.generate(package_payload)
  end

  def load_mutated_payload(environment: build_environment)
    payload = JSON.parse(package_json)
    yield payload
    CompiledTemplate.load(JSON.generate(payload), environment: environment, max_nodes: 100)
  end

  def assert_compiled_error(message_pattern)
    payload = JSON.parse(package_json)
    yield payload
    error = assert_raises(CompiledTemplateError) do
      CompiledTemplate.load(JSON.generate(payload), max_nodes: 100)
    end
    assert_match(message_pattern, error.message)
  end

  def run_child_process(payload)
    script = <<~'RUBY'
      require 'json'
      $LOAD_PATH.unshift(File.join(ENV.fetch('LIQUID_LIB'), 'lib'))
      require 'liquid'

      module ExplodeFilter
        def explode(value)
          raise "boom for #{value}"
        end
      end

      class RegisteredTag < Liquid::Tag
        def render(context)
          "tag #{context['tag_input']}"
        end
      end

      input = JSON.parse($stdin.read)
      values = { 'snippet' => "snippet {{ tag_input | upcase }} {% registered %}" }
      file_system = Object.new
      file_system.define_singleton_method(:read_template_file) { |name| values.fetch(name) }
      environment = Liquid::Environment.new
      environment.file_system = file_system
      environment.error_mode = :strict2
      environment.register_filter(ExplodeFilter)
      environment.register_tag('registered', RegisteredTag)
      environment.freeze
      template = Liquid::CompiledTemplate.load(JSON.generate(input), environment: environment, name: 'products')
      cases = JSON.parse(ENV.fetch('LIQUID_CASES'))
      results = cases.transform_values do |assigns|
        begin
          { 'ok' => true, 'output' => template.render!(assigns, strict_variables: true) }
        rescue Liquid::Error, StandardError => error
          {
            'ok' => false,
            'class' => error.class.name,
            'message' => error.message,
            'line' => (error.line_number if error.respond_to?(:line_number)),
            'template' => (error.template_name if error.respond_to?(:template_name)),
          }
        end
      end
      results['status'] = 'ok'
      $stdout.write(JSON.generate(results))
    RUBY

    child_environment = {
      'LIQUID_LIB' => File.expand_path('../..', __dir__),
      'LIQUID_CASES' => JSON.generate(cases),
    }
    stdout, stderr, status = Open3.capture3(
      child_environment,
      Gem.ruby,
      '-e',
      script,
      stdin_data: payload,
    )
    raise "compiled template child process failed: #{stderr}\n#{stdout}" unless status.success?
    JSON.parse(stdout)
  end
end
