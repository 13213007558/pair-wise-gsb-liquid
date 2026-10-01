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
        capture_output = +''
        if context.html_safety
          context.html_safety.begin_capture
          begin
            @body.render_to_output_buffer(context, capture_output)
            capture_output = context.html_safety.end_capture(capture_output)
          rescue
            context.html_safety.abort_capture
            raise
          end
        else
          @body.render_to_output_buffer(context, capture_output)
        end
        context.scopes.last[@to] = capture_output
      end
      output
    end

    def blank?
      true
    end
  end
end
