# frozen_string_literal: true

require 'liquid/tag/disabler'
require 'liquid/tag/disableable'

module Liquid
  class Tag
    attr_reader :nodelist, :tag_name, :line_number, :parse_context
    alias_method :options, :parse_context
    include ParserSwitching

    class << self
      def parse(tag_name, markup, tokenizer, parse_context)
        tag = new(tag_name, markup, parse_context)
        tag.parse(tokenizer)
        tag
      end

      def disable_tags(*tag_names)
        tag_names += disabled_tags
        define_singleton_method(:disabled_tags) { tag_names }
        prepend(Disabler)
      end

      private :new

      protected

      def disabled_tags
        []
      end
    end

    def initialize(tag_name, markup, parse_context)
      @tag_name      = tag_name
      @markup        = markup
      @parse_context = parse_context
      @line_number   = parse_context.line_number
    end

    def self.compiled(tag_name, markup, parse_context, line_number: nil)
      instance = allocate
      instance.instance_variable_set(:@tag_name, tag_name)
      instance.instance_variable_set(:@markup, markup)
      instance.instance_variable_set(:@parse_context, parse_context)
      instance.instance_variable_set(:@line_number, line_number)
      instance
    end

    def self.from_compiled_tag(data, parse_context)
      tag = send(:new, data.fetch('tag_name'), data.fetch('markup').to_s, parse_context)
      tag.instance_variable_set(:@line_number, data['line_number'])
      tag.compiled_tag_data = data if tag.respond_to?(:compiled_tag_data=)
      tag
    end

    def compiled_tag_payload
      nil
    end

    attr_accessor :compiled_tag_data

    def parse(_tokens)
    end

    def raw
      "#{@tag_name} #{@markup}"
    end

    def name
      self.class.name.downcase
    end

    def render(_context)
      ''
    end

    # For backwards compatibility with custom tags. In a future release, the semantics
    # of the `render_to_output_buffer` method will become the default and the `render`
    # method will be removed.
    def render_to_output_buffer(context, output)
      render_result = render(context)
      output << render_result if render_result
      output
    end

    def blank?
      false
    end

    private

    def safe_parse_expression(parser)
      parse_context.safe_parse_expression(parser)
    end

    def parse_expression(markup, safe: false)
      parse_context.parse_expression(markup, safe: safe)
    end
  end
end
