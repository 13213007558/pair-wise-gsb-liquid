# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path('../../lib', __dir__))
require 'liquid'
require 'json'

class CompiledRoundtripFileSystem
  def initialize(values)
    @values = values
  end

  def read_template_file(name)
    @values.fetch(name)
  end
end

module CompiledRoundtripFilters
  def shout(value)
    value.to_s.upcase
  end

  def explode(value)
    raise Liquid::StandardError, 'filter explosion' if value == 'boom'
    value
  end
end

class CompiledQuestionTag < Liquid::Tag
  def initialize(tag_name, markup, parse_context)
    super
    @question = markup.strip
  end

  def render_to_output_buffer(_context, output)
    output << "Question: #{@question}"
    output
  end
end

class CompiledWrapTag < Liquid::Block
  def initialize(tag_name, markup, parse_context)
    super
    raise Liquid::SyntaxError, 'wrap requires a label' unless markup.strip == 'result'
  end

  def render(context)
    "<wrap>#{super}</wrap>"
  end
end

module CompiledTemplateRoundtripHelper
  SOURCE = <<~LIQUID
    {{ greeting | shout }}
    {% compiledquestion ready? %}
    {% compiledwrap result %}loop:{% for item in items %}[{{ item.name }}]{% else %}empty{% endfor %}{% endcompiledwrap %}
    {% if score >= 10 and active %}yes{% else %}no{% endif %}
    {% case mode %}{% when 'a' %}A{% when 'b' %}B{% else %}C{% endcase %}
    {% render 'card', greeting: greeting %}
    {{ missing.value }}
    {{ value | explode }}
  LIQUID

  PARTIALS = {
    'card' => "Snippet: {{ greeting | shout }}",
  }.freeze

  def self.environment
    file_system = CompiledRoundtripFileSystem.new(PARTIALS)
    Liquid::Environment.build(file_system: file_system) do |env|
      env.register_filter(CompiledRoundtripFilters)
      env.register_tag('compiledquestion', CompiledQuestionTag)
      env.register_tag('compiledwrap', CompiledWrapTag)
    end
  end

  def self.parse
    Liquid::Template.parse(SOURCE, environment: environment, line_numbers: true).tap do |template|
      template.name = 'roundtrip/main'
    end
  end

  def self.assigns
    {
      'greeting' => 'hello',
      'items' => [{ 'name' => 'one' }, { 'name' => 'two' }],
      'score' => 11,
      'active' => true,
      'mode' => 'b',
      'value' => 'safe',
    }
  end

  def self.results(template)
    {
      'normal' => template.render(assigns, registers: registers),
      'undefined' => exception(template, assigns, {}, true),
      'filter_failure' => exception(template, assigns, { 'value' => 'boom' }, false),
    }
  end

  def self.registers
    { file_system: CompiledRoundtripFileSystem.new(PARTIALS) }
  end

  def self.exception(template, assigns, overrides, strict_variables)
    template.render!(assigns.merge(overrides), registers: registers, strict_variables: strict_variables)
    nil
  rescue Liquid::Error => error
    {
      'class' => error.class.name,
      'message' => error.message,
      'line_number' => error.line_number,
      'template_name' => error.template_name,
    }
  end
end
