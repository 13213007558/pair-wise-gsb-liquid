# frozen_string_literal: true

module Liquid
  class Specializer
    # Nodes emitted by the specialization transformation. They render exactly
    # like the constructs they replace but are inert at parse time.

    # Emits nothing but increments the render score by +render_score+. These
    # nodes stand in for collapsed tags. Each inlined node and the tag charge
    # are accounted for explicitly so resource-limit thresholds are enforced
    # at the same budgets as in the original template. The threshold check is
    # inclusive (>=), matching the moment the original's one-shot enclosing
    # BlockBody charge crossed the limit.
    #
    # @api private
    class StaticCharge
      def initialize(render_score)
        @render_score = render_score
      end

      attr_reader :render_score

      def skip_slot_charge?
        true
      end

      def render_to_output_buffer(context, output)
        limits = context.resource_limits
        limits.increment_render_score(@render_score)
        if limits.render_score_limit && limits.render_score >= limits.render_score_limit
          # Reaching the configured budget trips the limit, just as the
          # original enclosing BlockBody's one-shot charge did at this point.
          limits.instance_variable_set(:@reached_limit, true)
          raise MemoryError, "Memory limits exceeded"
        end
        output
      end

      def blank?
        true
      end

      def line_number
        nil
      end
    end

    # Renders a node that was inlined from a collapsed construct's nested
    # body. Its slot in the enclosing BlockBody is not charged (each inlined
    # node charges one explicitly, in order); the +score+ is added right
    # before delegating to the wrapped node so limit thresholds are reached at
    # the same points as in the original nested BlockBody.
    #
    # @api private
    class InlineNode
      def initialize(node, score = 1)
        @node = node
        @score = score
      end

      def skip_slot_charge?
        true
      end

      def render_to_output_buffer(context, output)
        limits = context.resource_limits
        limits.increment_render_score(@score)
        if limits.render_score_limit && limits.render_score >= limits.render_score_limit
          limits.instance_variable_set(:@reached_limit, true)
          raise MemoryError, "Memory limits exceeded"
        end
        if @node.instance_of?(String)
          output << @node
        else
          @node.render_to_output_buffer(context, output)
        end
      end

      def blank?
        @node.respond_to?(:blank?) ? @node.blank? : false
      end

      def line_number
        @node.respond_to?(:line_number) ? @node.line_number : nil
      end
    end

    # Binds a precomputed plain value to a variable at render time, applying
    # the render's global filter (mirroring {{ value }}) and charging the same
    # assign score a normal {% assign %} would.
    #
    # @api private
    class StaticAssign
      def initialize(variable_name, value, assign_score)
        @variable_name = variable_name
        @value = value
        @assign_score = assign_score
      end

      attr_reader :variable_name, :value

      def render_to_output_buffer(context, output)
        val = context.apply_global_filter(@value)
        context.scopes.last[@variable_name] = val
        context.resource_limits.increment_assign_score(@assign_score)
        output
      end

      def blank?
        true
      end

      def line_number
        nil
      end
    end
    # A fully folded {% capture %}: reproduces its captured render score,
    # binds the fixed captured string and charges identical assign score.
    #
    # @api private
    class StaticCaptureAssign
      def initialize(variable_name, captured, assign_score, render_score)
        @variable_name = variable_name
        @captured = captured
        @assign_score = assign_score
        @render_score = render_score
      end

      def render_to_output_buffer(context, output)
        context.resource_limits.with_capture do
          # Body render score was accrued while the captured string was built.
          context.resource_limits.increment_render_score(@render_score)
          context.scopes.last[@variable_name] = @captured
          context.resource_limits.increment_assign_score(@assign_score)
        end
        output
      end

      def blank?
        true
      end

      def line_number
        nil
      end
    end
  end
end
