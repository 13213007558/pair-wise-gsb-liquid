# frozen_string_literal: true

module Liquid
  # @liquid_public_docs
  # @liquid_type tag
  # @liquid_category variable
  # @liquid_name capture
  # @liquid_summary
  #   Creates a new variable with a string value.
  # @liquid_description
  #   You can create complex strings with Liquid logic and variables.
  #
  #   > Caution:
  #   > Predefined Liquid objects can be overridden by variables with the same name.
  #   > To make sure that you can access all Liquid objects, make sure that your variable name doesn't match a predefined object's name.
  # @liquid_syntax
  #   {% capture variable %}
  #     value
  #   {% endcapture %}
  # @liquid_syntax_keyword variable The name of the variable being created.
  # @liquid_syntax_keyword value The value you want to assign to the variable.
  class Capture < Block
    include ParserSwitching

    Syntax = /(#{VariableSignature}+)/o

    attr_reader :to

    def initialize(tag_name, markup, options)
      super
      @html_autoescape = options.html_autoescape?
      parse_with_selected_parser(markup)
    end

    def lax_parse(markup)
      if markup =~ Syntax
        @to = Regexp.last_match(1)
      else
        raise SyntaxError, options[:locale].t("errors.syntax.capture")
      end
    end

    def strict_parse(markup)
      lax_parse(markup)
    end

    def strict2_parse(markup)
      p = @parse_context.new_parser(markup.strip)
      @to = p.consume(:id)
      p.consume(:end_of_string)
    end

    def render_to_output_buffer(context, output)
      context.resource_limits.with_capture do
        capture_output = render(context)
        # Captured content is fully rendered markup: mark it as safe HTML so
        # that outputting it again does not escape it a second time.
        capture_output = SafeString.new(capture_output, :html) if @html_autoescape
        context.scopes.last[@to] = capture_output
      end
      output
    end

    def blank?
      true
    end
  end
end
