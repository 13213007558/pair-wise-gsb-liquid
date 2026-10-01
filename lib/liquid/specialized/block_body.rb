# frozen_string_literal: true

module Liquid
  module Specialized
    # BlockBody produced by Template#specialize.
    #
    # Every item in the nodelist is a fused node (raw text and fully known
    # variables are folded into FusedOutput). Rendering semantics mirror
    # Liquid::BlockBody: render-score is charged once for the whole body,
    # interrupts abort processing, and errors raised by a node are handled
    # exactly as in the original engine.
    #
    # Write-score / render-length accounting is performed by the fused nodes
    # themselves (FusedOutput checks once per original chunk), so this body
    # does not add a per-node write check.
    class BlockBody
      attr_reader :nodelist, :render_score_weight

      def initialize(nodelist, render_score_weight)
        @nodelist = nodelist
        @render_score_weight = render_score_weight
        freeze
      end

      def freeze
        @nodelist.freeze
        super
      end

      def blank?
        true
      end

      def remove_blank_strings
        raise "remove_blank_strings only support being called on a blank block body"
      end

      def render(context)
        render_to_output_buffer(context, +'')
      end

      def render_to_output_buffer(context, output)
        context.resource_limits.increment_render_score(@render_score_weight)

        idx = 0
        while (node = @nodelist[idx])
          Liquid::BlockBody.render_node(context, output, node)
          break if context.interrupt? # might have happened in a for-block
          idx += 1
        end

        output
      end
    end
  end
end
