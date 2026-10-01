# frozen_string_literal: true

module Liquid
  # Optional output provenance ("source map") support.
  #
  # Provenance tracking is strictly opt-in: Template#render keeps returning a
  # plain String and pays no tracking cost. Use Template#render_with_provenance
  # (or pass a Liquid::Provenance::Tracker via the `:provenance` render option)
  # to additionally obtain a Liquid::Provenance::Map describing, for every byte
  # range of the output that originated from a variable, which expression
  # produced it, at which template/line it was rendered, and which filters the
  # value passed through.
  #
  # The map stores metadata only: variable names, template names, line numbers,
  # byte ranges and filter names. It never stores a copy of the rendered
  # values, so it is safe to use with sensitive assigns.
  #
  # Filters may declare an exact byte-level mapping through
  # Liquid::Provenance.register_filter_mapper. When a filter has no declared
  # mapping, the whole filtered output is marked as depending on all of the
  # input's sources (Span#exact? is false) instead of fabricating a
  # character-by-character correspondence.
  module Provenance
    # Describes where a value (or a byte range of a value) originates from.
    class Source
      # The expression that produced the value, e.g. "product.title".
      attr_reader :variable
      # Name of the template (or partial) the expression was rendered in, if known.
      attr_reader :template_name
      # Line number of the {{ }} / {% %} construct, if line numbers were enabled.
      attr_reader :line_number
      # Byte range within the source value this span corresponds to.
      # nil means "the whole value" or "unknown".
      attr_reader :input_range

      def initialize(variable:, template_name:, line_number:, input_range: nil)
        @variable      = variable
        @template_name = template_name
        @line_number   = line_number
        @input_range   = input_range
      end

      def with_input_range(range)
        Source.new(variable: @variable, template_name: @template_name, line_number: @line_number, input_range: range)
      end

      def without_input_range
        @input_range.nil? ? self : Source.new(variable: @variable, template_name: @template_name, line_number: @line_number)
      end

      # Same template position, different expression (used for filter arguments).
      def derive(variable:)
        Source.new(variable: variable, template_name: @template_name, line_number: @line_number)
      end

      def identity
        [@variable, @template_name, @line_number]
      end

      def ==(other)
        other.is_a?(Source) && identity == other.identity && input_range == other.input_range
      end
      alias_method :eql?, :==

      def hash
        identity.hash
      end

      def to_s
        location = @template_name ? "#{@template_name}:#{@line_number}" : "line #{@line_number}"
        "#{@variable} (#{location})"
      end
      alias_method :inspect, :to_s
    end

    # Maps a byte range of a rendered value (or of the final output) back to
    # its origin. When `exact` is false, a filter without a declared mapping
    # was involved: the whole range then depends on all of `sources` and no
    # byte-level correspondence is implied.
    class Span
      attr_reader :start, :end, :sources, :filters

      def initialize(start, finish, sources, filters, exact)
        @start   = start
        @end     = finish
        @sources = sources.freeze
        @filters = filters.freeze
        @exact   = exact
      end

      def exact?
        @exact
      end

      def range
        @start...@end
      end

      def length
        @end - @start
      end

      def shifted(offset)
        Span.new(@start + offset, @end + offset, @sources, @filters, @exact)
      end

      def with_filter(filter_name)
        Span.new(@start, @end, @sources, @filters + [filter_name], @exact)
      end

      def to_s
        "#<Span #{@start}...#{@end} #{@exact ? 'exact' : 'coarse'} sources=#{@sources.inspect} filters=#{@filters.inspect}>"
      end
      alias_method :inspect, :to_s
    end

    # A String that carries its provenance spans while flowing through
    # {% assign %}, {% capture %} and {% render %} parameters. This is the
    # value itself (not a copy kept on the side); the final provenance map
    # only keeps the metadata.
    class TrackedString < String
      attr_reader :spans

      def initialize(str, spans)
        super(str)
        @spans = spans
      end
    end

    # Internal state while a {{ }} expression is evaluated and filtered.
    # @api private
    class Evaluation
      attr_reader :value, :spans, :site

      def initialize(value, spans, site, fallback_sources, fallback_filters)
        @value            = value
        @spans            = spans
        @site             = site
        @fallback_sources = fallback_sources
        @fallback_filters = fallback_filters
      end

      def sources
        if @spans
          sources = @spans.flat_map(&:sources).map(&:without_input_range).uniq
          sources.empty? ? @fallback_sources : sources
        else
          @fallback_sources
        end
      end

      def filters
        if @spans
          @spans.flat_map(&:filters).uniq
        else
          @fallback_filters
        end
      end
    end

    # Records provenance spans during a single render. Sinks are stacked so
    # that constructs rendering into a side buffer ({% capture %},
    # {% ifchanged %}) can collect spans relative to that buffer and re-anchor
    # them when the buffer is appended to the real output.
    # @api private
    class Tracker
      def initialize
        @sinks = [[]]
      end

      # Spans recorded against the root output buffer.
      def spans
        @sinks.first
      end

      # Records `value_spans` (relative to a value being appended) at the
      # given byte offset of the current output sink.
      def record(value_spans, offset)
        sink = @sinks.last
        value_spans.each do |span|
          sink << span.shifted(offset)
        end
      end

      # Runs the block with a fresh local sink and returns the spans recorded
      # while it ran (relative to the local buffer).
      def capture
        @sinks << []
        begin
          yield
        ensure
          local = @sinks.pop
        end
        local
      end

      # Builds the initial evaluation state for a {{ }} expression.
      def initial_evaluation(expression, value, context, node)
        site = Source.new(
          variable:      Provenance.describe_expression(expression),
          template_name: context.template_name,
          line_number:   node.line_number,
        )

        case value
        when TrackedString
          # The value already carries its own provenance (capture/assign/render).
          sources = value.spans.flat_map(&:sources).map(&:without_input_range).uniq
          sources = [site] if sources.empty?
          filters = value.spans.flat_map(&:filters).uniq
          Evaluation.new(value, value.spans, site, sources, filters)
        when String
          span = Span.new(0, value.bytesize, [site.with_input_range(0...value.bytesize)], [], true)
          Evaluation.new(value, [span], site, [site], [])
        else
          Evaluation.new(value, nil, site, [site], [])
        end
      end

      # Applies a filter to the current evaluation. Yields the filter input
      # and expects the filter output as the block result.
      def apply_filter(evaluation, filter_name, filter_args, raw_args)
        input  = evaluation.value
        output = yield(input)
        filters = evaluation.filters + [filter_name]

        spans = nil
        if output.is_a?(String) && evaluation.spans && input.is_a?(String) &&
           (mapper = Provenance.filter_mapper(filter_name))
          # A mapper that cannot stay exact (or misbehaves) falls back to a
          # coarse dependency rather than fabricating a mapping.
          spans = begin
            mapper.call(input, evaluation.spans, output, filter_args, raw_args, evaluation.site)
          rescue StandardError
            nil
          end
        end

        if spans.nil? && output.is_a?(String)
          # No declared mapping (or the mapper could not stay exact): the whole
          # output depends on all input sources. Do not fabricate a mapping.
          sources = evaluation.sources
          spans = [Span.new(0, output.bytesize, sources, filters, false)]
        end

        Evaluation.new(output, spans, evaluation.site, evaluation.sources, filters)
      end

      # The global filter is opaque to provenance: mark the whole result as a
      # coarse dependency of everything that fed into it.
      def apply_global_filter(evaluation, output)
        return evaluation if output.equal?(evaluation.value)

        sources = evaluation.sources
        filters = evaluation.filters
        spans = output.is_a?(String) ? [Span.new(0, output.bytesize, sources, filters, false)] : nil
        Evaluation.new(output, spans, evaluation.site, sources, filters)
      end

      # Wraps the final value of an expression so provenance survives being
      # stored via {% assign %} and passed to {% render %}.
      def to_value(evaluation)
        value = evaluation.value
        if value.is_a?(String) && !value.is_a?(TrackedString)
          spans = evaluation.spans || [Span.new(0, value.bytesize, evaluation.sources, evaluation.filters, false)]
          TrackedString.new(value, spans)
        else
          value
        end
      end

      # Appends the evaluated value to the output buffer, recording spans.
      def write(evaluation, output)
        value = evaluation.value
        if value.is_a?(String) && evaluation.spans && !evaluation.spans.empty?
          unless value.empty?
            start = output.bytesize
            output << value
            record(evaluation.spans, start)
          end
        else
          write_value(value, output, evaluation.sources, evaluation.filters)
        end
        output
      end

      private

      def write_value(value, output, fallback_sources, fallback_filters)
        case value
        when NilClass
          # nothing emitted
        when Array
          value.each { |element| write_value(element, output, fallback_sources, fallback_filters) }
        when TrackedString
          start = output.bytesize
          output << value
          record([Span.new(0, value.bytesize, fallback_sources, fallback_filters, false)], start) unless value.empty?
        else
          str = Utils.to_s(value)
          return if str.empty?

          start = output.bytesize
          output << str
          record([Span.new(0, str.bytesize, fallback_sources, fallback_filters, false)], start)
        end
      end
    end

    # The immutable result of a provenance-tracked render: a sorted list of
    # spans over the rendered output. Byte ranges not covered by any span
    # correspond to literal template text.
    class Map
      include Enumerable

      attr_reader :spans
      alias_method :entries, :spans

      def initialize(spans)
        @spans = spans.sort_by(&:start).freeze
      end

      def each(&block)
        @spans.each(&block)
      end

      # All spans overlapping the given byte range of the output. Accepts a
      # Range or an (offset, length) pair.
      def query(range_or_offset, length = nil)
        if range_or_offset.is_a?(Range)
          first = range_or_offset.begin
          last  = range_or_offset.exclude_end? ? range_or_offset.end : range_or_offset.end + 1
        else
          first = range_or_offset
          last  = range_or_offset + (length || 1)
        end
        @spans.select { |span| span.start < last && span.end > first }
      end

      # All spans covering the given byte offset of the output.
      def at(offset)
        query(offset)
      end
    end

    # Return value of Template#render_with_provenance.
    class Result
      attr_reader :output, :provenance

      def initialize(output, provenance)
        @output     = output
        @provenance = provenance
      end

      def to_s
        @output.to_s
      end
    end

    @filter_mappers = {}

    class << self
      # Declares an exact byte-level mapping for a filter. The block receives
      #   (input_string, input_spans, output_string, evaluated_args, arg_expressions, site)
      # and must return spans relative to the output string, or nil to fall
      # back to a coarse whole-output dependency.
      def register_filter_mapper(filter_name, &block)
        @filter_mappers[filter_name.to_s] = block
      end

      def unregister_filter_mapper(filter_name)
        @filter_mappers.delete(filter_name.to_s)
      end

      def filter_mapper(filter_name)
        @filter_mappers[filter_name]
      end

      # Human-readable description of a parsed expression, used as
      # Source#variable. Never contains the runtime value.
      def describe_expression(expression)
        case expression
        when VariableLookup
          parts = [expression.name]
          expression.lookups.each do |lookup|
            parts << (lookup.is_a?(String) ? lookup : describe_expression(lookup))
          end
          parts.join('.')
        when String
          expression.inspect
        when nil
          'nil'.dup
        else
          expression.to_s
        end
      end

      # Appends `span` to `spans`, merging with the previous span when both
      # describe adjacent ranges of the same source(s) with the same filters.
      def push_span(spans, span)
        last = spans.last
        if last && last.end == span.start && last.exact? == span.exact? &&
           last.filters == span.filters && mergeable_sources?(last.sources, span.sources)
          merged_sources = last.sources.each_index.map do |i|
            left  = last.sources[i]
            right = span.sources[i]
            if left.input_range && right.input_range && left.input_range.end == right.input_range.begin
              left.with_input_range(left.input_range.begin...right.input_range.end)
            else
              left.without_input_range
            end
          end
          spans[-1] = Span.new(last.start, span.end, merged_sources, last.filters, last.exact?)
        else
          spans << span
        end
        spans
      end

      # Returns spans for the sub-range [offset, offset + length) of the
      # current value, shifted to be relative to that sub-range, with
      # `filter_name` recorded on each surviving span.
      def clip_spans(spans, offset, length, filter_name)
        result = []
        limit  = offset + length
        spans.each do |span|
          start  = span.start > offset ? span.start : offset
          finish = span.end < limit ? span.end : limit
          next if start >= finish

          clipped = if start == span.start && finish == span.end
            span
          else
            sources = span.sources.map { |source| clip_source(source, span, start, finish) }
            Span.new(start, finish, sources, span.filters, span.exact?)
          end
          push_span(result, clipped.with_filter(filter_name).shifted(-offset))
        end
        result
      end

      # Builds spans for a filter argument string (used by append/prepend/
      # default). TrackedString arguments keep their own provenance; anything
      # else is attributed to the argument expression at the current site.
      def argument_spans(arg, raw_arg, site)
        return nil unless arg.is_a?(String)

        if arg.is_a?(TrackedString)
          arg.spans
        else
          source = site.derive(variable: describe_expression(raw_arg))
          [Span.new(0, arg.bytesize, [source], [], true)]
        end
      end

      private

      def mergeable_sources?(left, right)
        left.length == right.length &&
          left.each_index.all? { |i| left[i].identity == right[i].identity }
      end

      def clip_source(source, span, start, finish)
        range = source.input_range
        return source unless range

        if range.size == span.length
          # 1:1 byte correspondence between the value range and the source range
          shift = start - span.start
          source.with_input_range((range.begin + shift)...(range.begin + shift + finish - start))
        else
          # The source range has a different length than the value range
          # (e.g. a case conversion expanded a character); the exact offset
          # within the source is not computable, so drop it.
          source.without_input_range
        end
      end
    end
  end
end

require 'liquid/provenance/standard_filter_mappers'
