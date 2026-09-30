# frozen_string_literal: true

module Liquid
  # @liquid_public_docs
  # @liquid_type tag
  # @liquid_category iteration
  # @liquid_name continue
  # @liquid_summary
  #   Causes a [`for` loop](/docs/api/liquid/tags/for) to skip to the next iteration.
  # @liquid_description
  #   An optional label (ex: `{% continue outer %}`) skips to the next
  #   iteration of the enclosing [`for` loop](/docs/api/liquid/tags/for) that
  #   declared that label with `label:`, unwinding any loops in between.
  # @liquid_syntax
  #   {% continue %}
  # @liquid_syntax
  #   {% continue label %}
  class Continue < Tag
    INTERRUPT = ContinueInterrupt.new.freeze
    LABEL_SYNTAX = /\A[a-zA-Z_][\w\-]*\z/

    def initialize(tag_name, markup, options)
      super
      @interrupt = INTERRUPT

      label = markup.to_s.strip
      return if label.empty?

      unless label.match?(LABEL_SYNTAX)
        raise SyntaxError, options[:locale].t("errors.syntax.continue_invalid_label", label: label)
      end
      unless parse_context.for_label?(label)
        raise SyntaxError, options[:locale].t("errors.syntax.continue_unknown_label", label: label)
      end

      @interrupt = ContinueInterrupt.new(label).freeze
    end

    def render_to_output_buffer(context, output)
      context.push_interrupt(@interrupt)
      output
    end
  end
end
