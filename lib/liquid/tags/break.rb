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
  # == Labeled Usage:
  #    {% for group in groups label: outer %}
  #      {% for item in group.items %}
  #        {% if item.found %}
  #          {% break outer %}
  #        {% endif %}
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
  # @liquid_syntax
  #   {% break label %}
  class Break < Tag
    INTERRUPT = BreakInterrupt.new.freeze
    LABEL_SYNTAX = /\A[a-zA-Z_][\w\-]*\z/

    def initialize(tag_name, markup, options)
      super
      @interrupt = INTERRUPT

      label = markup.to_s.strip
      return if label.empty?

      unless label.match?(LABEL_SYNTAX)
        raise SyntaxError, options[:locale].t("errors.syntax.break_invalid_label", label: label)
      end
      unless parse_context.for_label?(label)
        raise SyntaxError, options[:locale].t("errors.syntax.break_unknown_label", label: label)
      end

      @interrupt = BreakInterrupt.new(label).freeze
    end

    def render_to_output_buffer(context, output)
      context.push_interrupt(@interrupt)
      output
    end
  end
end
