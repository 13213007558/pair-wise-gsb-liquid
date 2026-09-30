# frozen_string_literal: true

module Liquid
  # Break tag to be used to break out of a for loop.
  #
  # == Basic Usage:
  #    {% for item in collection %}
  #      {% if item.condition %}
  #        {% break %}
  #      {% endif %}
  #    {% endfor %}
  #
  # == Breaking out of an outer, labeled loop:
  #    {% for group in groups, label: groups %}
  #      {% for item in group %}
  #        {% if item.found %}{% break groups %}{% endif %}
  #      {% endfor %}
  #    {% endfor %}
  #
  # @liquid_public_docs
  # @liquid_type tag
  # @liquid_category iteration
  # @liquid_name break
  # @liquid_summary
  #   Stops a [`for` loop](/docs/api/liquid/tags/for) from iterating.
  # @liquid_syntax
  #   {% break %}
  # @liquid_syntax_keyword label [string] Optionally, the label of an enclosing `for` loop to break out of.
  class Break < Tag
    INTERRUPT = BreakInterrupt.new.freeze

    LabelSyntax = /\A[a-zA-Z_][\w\-]*\z/

    attr_reader :label

    def initialize(tag_name, markup, options)
      super
      @label     = parse_label(markup)
      @interrupt = @label ? BreakInterrupt.new(@label).freeze : INTERRUPT
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
