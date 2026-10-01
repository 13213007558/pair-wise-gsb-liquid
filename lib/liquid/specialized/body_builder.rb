# frozen_string_literal: true

module Liquid
  module Specialized
    # Accumulates the specialized contents of one block body and finalizes
    # them into a Liquid::Specialized::BlockBody.
    #
    # Consecutive output-producing items (raw text and fully folded or
    # surviving {{ variables }}) are coalesced into a single FusedOutput
    # node. Non-output tags (assign/capture/loops/...) interrupt the run.
    #
    # Every item carries the render-score weight of the original node(s) it
    # replaces, so observable resource limits cannot be bypassed by folding.
    class BodyBuilder
      def initialize(specializer = nil)
        @global_filter = specializer&.global_filter
        @items = []
        @run_chunks = nil
        @run_weight = 0
        @static_only = true
      end

      # Append a fully folded piece of raw template text.
      def add_text(text)
        open_run
        @run_chunks << [:text, text]
        @run_weight += 1
      end

      # Append text produced by a fully folded {{ variable }}. Unlike raw
      # template text, it is subject to the global filter at render time.
      def add_folded_text(text)
        open_run
        @run_chunks << [:vtext, text]
        @run_weight += 1
      end

      # Append a surviving {{ variable }} to the current output run.
      def add_variable(variable)
        @static_only = false
        open_run
        @run_chunks << [:var, variable]
        @run_weight += 1
      end

      # Append a node that renders output but cannot be chunked (raw, echo,
      # surviving control tags, custom tags, ...).
      def add_passthrough(node, weight: 1, write_checks: 1)
        flush_run
        @static_only = false unless node.is_a?(Raw)
        @items << Passthrough.new(
          node, render_score_weight: weight, write_score_count: write_checks
        )
      end

      # Append a fused non-output node (FusedAssign/FusedCapture).
      def add_node(node)
        flush_run
        @items << node
      end

      # Add render-score weight without producing output (used to account
      # for eliminated conditionals). It rides along in the surrounding
      # output run or becomes a zero-chunk FusedOutput.
      def add_weight_only(weight)
        open_run
        @run_weight += weight
      end

      # Merge another builder's contents (selected static branches).
      def merge(other)
        flush_run
        other.flush_run
        @items.concat(other.items)
        @static_only &&= other.static_only?
        self
      end

      # Merge an already-built Specialized::BlockBody's nodes (the contents
      # may be dynamic).
      def merge_body(body)
        flush_run
        @items.concat(body.nodelist)
        @static_only = false
        self
      end

      def build
        flush_run
        total_weight = @items.sum(&:render_score_weight)
        BlockBody.new(@items, total_weight)
      end

      def static_only?
        @static_only
      end

      # Renders the fully-static accumulated content to a string, applying
      # the global filter to folded variable chunks exactly as rendering would.
      def materialized_string
        raise CannotFold unless static_only?
        flush_run
        buf = +''
        @items.each do |item|
          item.chunks.each do |kind, payload|
            case kind
            when :text
              buf << payload
            when :vtext
              buf << (@global_filter ? @global_filter.call(payload) : payload)
            end
          end
        end
        buf
      end

      attr_reader :items

      def flush_run
        return unless @run_chunks
        if @run_chunks.any? || @run_weight.positive?
          @items << FusedOutput.new(
            @run_chunks,
            line_number: nil,
            render_score_weight: @run_weight,
            global_filter: @global_filter,
          )
        end
        @run_chunks = nil
        @run_weight = 0
      end

      private

      def open_run
        @run_chunks ||= []
      end
    end
  end
end
