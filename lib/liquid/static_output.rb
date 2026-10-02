# frozen_string_literal: true

module Liquid
  # Render-time node produced by the partial evaluator for an expression whose
  # value was fully determined by the variables known at preprocessing time.
  #
  # It reproduces {Variable} output semantics exactly (arrays are flattened,
  # nil produces nothing, and the template's global filter is still applied at
  # render time) while never depending on render-time variables.
  #
  # @api private
  class StaticOutput
    attr_reader :value

    def initialize(value)
      @value = value
    end

    def render(context)
      render_to_output_buffer(context, +'')
    end

    def render_to_output_buffer(context, output)
      obj = context.apply_global_filter(@value)
      render_value(obj, output)
      output
    end

    def blank?
      false
    end

    def line_number
      nil
    end

    def disabled?(_context)
      false
    end

    private

    def render_value(value, output)
      case value
      when nil
        nil
      when Array
        value.each { |entry| render_value(entry, output) }
      else
        output << Liquid::Utils.to_s(value)
      end
    end
  end
end
