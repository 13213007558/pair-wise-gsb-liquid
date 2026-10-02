# frozen_string_literal: true

module Liquid
  # Document body used by templates produced by {Partial}. It is backed by an
  # already-constructed nodelist, so no re-parsing (and therefore no
  # whitespace/blank reinterpretation) takes place.
  #
  # @api private
  class ResidualDocument
    attr_reader :body, :nodes

    def initialize(nodes, blank)
      @nodes = nodes
      @body = ResidualBlockBody.new(nodes, blank)
    end

    def nodelist
      @nodes
    end

    def render_to_output_buffer(context, output)
      @body.render_to_output_buffer(context, output)
    end

    def render(context)
      render_to_output_buffer(context, +'')
    end
  end

  # @api private
  class ResidualBlockBody < BlockBody
    def initialize(nodes, blank)
      super()
      @nodelist = nodes
      @blank = blank
    end
  end
end
