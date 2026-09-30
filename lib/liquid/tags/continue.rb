# frozen_string_literal: true

module Liquid
  # Continue tag to be used to skip to the next iteration of a for loop.
  #
  # == Basic Usage:
  #    {% for item in collection %}
  #      {% if item.skip %}{% continue %}{% endif %}
  #    {% endfor %}
  #
  # == Continuing an outer, labeled loop:
  #    {% for group in groups, label: groups %}
  #      {% for item in group %}
  #        {% if item.found %}{% continue groups %}{% endif %}
  #      {% endfor %}
  #    {% endfor %}
  #
  # @liquid_public_docs
  # @liquid_type tag
  # @liquid_category iteration
  # @liquid_name continue
  # @liquid_summary
  #   Causes a [`for` loop](/docs/api/liquid/tags/for) to skip to the next iteration.
  # @liquid_syntax
  #   {% continue %}
  # @liquid_syntax_keyword label [string] Optionally, the label of an enclosing `for` loop to continue.
  class Continue < Tag
    INTERRUPT = ContinueInterrupt.new.freeze

    LabelSyntax = /\A[a-zA-Z_][\w\-]*\z/

    attr_reader :label

    def initialize(tag_name, markup, options)
      super
      @label     = parse_label(markup)
      @interrupt = @label ? ContinueInterrupt.new(@label).freeze : INTERRUPT
    end

    def render_to_output_buffer(context, output)
      context.push_interrupt(@interrupt)
      output
    end

    private

    def parse_label(markup)
      markup = markup.to_s.strip
      return nil if markup.empty?

      unless (matches = LabelSyntax.match(markup))
        raise SyntaxError, parse_context.locale.t("errors.syntax.invalid_loop_label", tag: tag_name)
      end

      label = matches[0]
      unless parse_context.for_label_stack.include?(label)
        raise SyntaxError, parse_context.locale.t(
          "errors.syntax.unknown_loop_label", tag: tag_name, label: label
        )
      end
      label
    end
  end
end
