# frozen_string_literal: true

module Liquid
  # Optional output provenance ("source map") support.
  #
  # Enable with the +source_map: true+ render option:
  #
  #   output = template.render!(assigns, source_map: true)
  #   output.class # => String (rendering still returns a plain String)
  #   template.source_map.spans(3, 7).each do |span|
  #     span.start, span.finish      # byte range in the output
  #     span.origins.first.variable  # which variable produced it
  #     span.origins.first.template  # which template / line
  #     span.origins.first.filters   # filters applied along the way
  #   end
  #
  # The map stores byte ranges and metadata only -- variable names, template
  # names, line numbers and filter chains. It never keeps a separate copy of a
  # variable's raw value: the string body carried by a TracedString is the
  # very output fragment that was rendered.
  module SourceMap
    # Mapping kinds a filter can declare. A filter that does not declare one
    # is treated conservatively: its whole output segment depends on the
    # input origins, with no fabricated per-character correspondence.
    #
    # * +:char_identity+ - output byte at offset i derives from input byte i
    #   (validated: falls back to whole-segment when byte lengths differ)
    # * +:slice+         - +input.slice(offset, length)+ semantics
    # * +:truncate+      - +truncate(length, suffix)+ keeps a prefix
    # * +:trim+ / +:ltrim+ / +:rtrim+ - whitespace removed from the edges
    # * +:append+ / +:prepend+ - a second argument is concatenated
    FILTER_MAPPINGS = {
      'upcase'     => :char_identity,
      'downcase'   => :char_identity,
      'capitalize' => :char_identity,
      'slice'      => :slice,
      'truncate'   => :truncate,
      'strip'      => :trim,
      'lstrip'     => :ltrim,
      'rstrip'     => :rtrim,
      'append'     => :append,
      'prepend'    => :prepend,
    }.freeze

    VALID_MAPPING_KINDS = %i[
      char_identity slice truncate trim ltrim rtrim append prepend
    ].freeze

    class << self
      # Declare that a filter has an exact output-byte -> input-byte mapping
      # of one of the known kinds in FILTER_MAPPINGS. This lets custom filters
      # reuse built-in mapping semantics instead of being reported as a
      # whole-segment dependency.
      def register_exact_filter(name, kind)
        unless VALID_MAPPING_KINDS.include?(kind)
          raise ArgumentError, "unknown source map filter mapping #{kind.inspect}"
        end

        exact_filters[name.to_s] = kind
      end

      def mapping_for(name)
        exact_filters[name.to_s]
      end

      def exact_filters
        @exact_filters ||= FILTER_MAPPINGS.dup
      end
    end

    # One provenance entry: where a value entered the render and which filters
    # it passed through afterwards.
    class Origin
      attr_reader :source, :variable, :template, :line_number, :markup, :filters

      def initialize(source:, variable: nil, template: nil, line_number: nil, markup: nil, filters: nil)
        @source = source
        @variable = variable
        @template = template
        @line_number = line_number
        @markup = markup
        @filters = filters ? filters.dup : []
      end

      def add_filter(name)
        @filters << name if name
        self
      end

      def dup
        self.class.new(
          source: @source, variable: @variable, template: @template,
          line_number: @line_number, markup: @markup, filters: @filters
        )
      end

      def ==(other)
        other.is_a?(Origin) && to_h == other.to_h
      end

      def eql?(other)
        self == other
      end

      def hash
        to_h.hash
      end

      def to_h
        hash = { source: @source }
        hash[:variable] = @variable if @variable
        hash[:template] = @template if @template
        hash[:line_number] = @line_number if @line_number
        hash[:markup] = @markup if @markup
        hash[:filters] = @filters.dup unless @filters.empty?
        hash
      end
    end

    # A String carrying a flat, byte-relative list of provenance segments:
    # [[byte_start, byte_length, [Origin, ...]], ...]. Segments are ordered,
    # non-overlapping and may leave gaps.
    #
    # Appending a TracedString into another buffer with #<< / #concat carries
    # its segments over, shifted to the insertion offset. Every existing
    # `output << fragment` write site in the renderer therefore propagates
    # provenance automatically -- loop repetitions, captured blocks and
    # rendered partials all append into the same buffer, so the same source
    # value emitted twice always produces two distinct segments.
    class TracedString < String
      attr_accessor :trace_nodes

      def initialize(*)
        super
        @trace_nodes ||= []
      end

      def initialize_copy(source)
        super
        if source.is_a?(TracedString)
          @trace_nodes = source.trace_nodes.map { |start, length, origins| [start, length, origins] }
        end
      end

      def <<(other)
        if other.is_a?(TracedString)
          base = bytesize
          super
          merge_nodes_from(other, base)
        else
          super
        end
      end

      def concat(*others)
        others.each { |other| self << other }
        self
      end

      def merge_nodes_from(other, base)
        other.trace_nodes.each do |start, length, origins|
          @trace_nodes << [start + base, length, origins]
        end
        self
      end

      def self.create(string, nodes)
        instance = new(string)
        instance.trace_nodes = nodes
        instance
      end
    end

    # Provenance for a non-string filter-chain value (e.g. `x | size`). A box
    # can be stored by {% assign %} and read back, so it behaves like its
    # value for reading operations (comparisons, arithmetic, stringification)
    # while keeping provenance attached. It never stores anything besides
    # what the value already is.
    class TracedBox
      attr_reader :value, :origins

      def initialize(value, origins)
        @value = value
        @origins = origins
      end

      # Context#find_variable calls #to_liquid: keep the box intact so a
      # later output still knows where the value came from.
      def to_liquid
        self
      end

      # Condition and Utils use #to_liquid_value to unwrap liquid values.
      def to_liquid_value
        @value.respond_to?(:to_liquid_value) ? @value.to_liquid_value : @value
      end

      def nil?
        @value.nil?
      end

      def ==(other)
        @value == other
      end

      def eql?(other)
        @value.eql?(other)
      end

      def hash
        @value.hash
      end

      def to_s
        @value.to_s
      end

      def to_str
        @value.to_str if @value.respond_to?(:to_str)
      end

      def to_i
        @value.to_i
      end

      def to_f
        @value.to_f
      end

      def inspect
        "#<Liquid::TracedBox #{@value.inspect}>"
      end

      # Delegate any other reading call (e.g. #>, #each, #size) to the value.
      def method_missing(name, *args, &block)
        @value.public_send(name, *args, &block)
      end

      def respond_to_missing?(name, include_private = false)
        @value.respond_to?(name, include_private) || super
      end
    end

    # Per-render tracker. Stored in the context's static registers, which the
    # isolated subcontexts of the +render+ tag share.
    class RenderTrace
      def new_buffer
        TracedString.new
      end

      # Record a run of literal template text about to be appended to buffer.
      def template_text!(buffer, string, context)
        return buffer if string.empty?

        buffer.trace_nodes << [
          buffer.bytesize, string.bytesize,
          [Origin.new(source: :template, template: context.template_name)]
        ]
        buffer
      end

      # Record a tag-produced string (e.g. increment/cycle output).
      def tag_output!(string, tag_name, context, line_number, markup)
        return string if string.nil? || string.empty?

        origin = Origin.new(
          source: :tag, variable: tag_name, template: context.template_name,
          line_number: line_number, markup: markup
        )
        TracedString.create(String.new(string), [[0, string.bytesize, [origin]]])
      end

      # --- origins ---------------------------------------------------------

      def variable_origin(expr, context, line_number)
        name = expression_name(expr)
        Origin.new(
          source: :variable, variable: name,
          template: context.template_name, line_number: line_number,
          markup: name
        )
      end

      def expression_origin(expr, context, line_number)
        if expr.is_a?(VariableLookup)
          variable_origin(expr, context, line_number)
        else
          Origin.new(
            source: :literal, template: context.template_name,
            line_number: line_number, markup: expr.is_a?(String) ? expr.inspect : nil
          )
        end
      end

      # Readable path for an expression: "user.name", "items[0]".
      def expression_name(expr)
        return nil unless expr.is_a?(VariableLookup)

        path = expr.name.to_s
        expr.lookups.each do |lookup|
          path += case lookup
          when VariableLookup then ".#{expression_name(lookup)}"
          when Integer then "[#{lookup}]"
          else ".#{lookup}"
          end
        end
        path
      end

      # --- entering a variable expression ---------------------------------

      # Wrap the evaluated input of a {{ }} expression before its filters.
      # Values that already carry provenance (captured output, an assigned
      # filter-chain result) keep it rather than being re-attributed.
      def enter(value, origin)
        case value
        when TracedString
          value
        when TracedBox
          value
        when String
          wrap_entire(value, [origin])
        when Array
          value.map { |item| enter(item, origin) }
        when nil
          nil
        else
          TracedBox.new(value, [origin])
        end
      end

      # Wrap a value flowing through a filter argument or a render/include
      # parameter, so concatenated arguments keep their own provenance.
      def wrap_argument(value, expr, context, line_number)
        case value
        when TracedString
          value
        when String
          wrap_entire(value, [expression_origin(expr, context, line_number)])
        when Array
          value.map { |item| wrap_argument(item, expr, context, line_number) }
        else
          value
        end
      end

      # --- filters ---------------------------------------------------------

      def apply_filter(context, name, current, args)
        raw_args = args.map { |arg| deep_unwrap(arg) }
        result = context.invoke(name, unwrap(current), *raw_args)
        remap(name.to_s, current, result, args)
      end

      def apply_global_filter(global_filter, current)
        remap(nil, current, global_filter.call(unwrap(current)), [])
      end

      # Turn chain values into renderable traced strings.
      def finalize(value)
        case value
        when TracedBox
          box_to_traced(value)
        when Array
          value.map { |item| item.is_a?(TracedBox) ? box_to_traced(item) : item }
        else
          value
        end
      end

      def box_to_traced(box)
        string = Liquid::Utils.to_s(box.value)
        wrap_entire(string, box.origins.map(&:dup))
      end

      private

      def remap(name, current, result, args)
        return nil if result.nil?

        input_origins = collect_origins(current)

        case result
        when String
          mapping = name && ::Liquid::SourceMap.mapping_for(name)
          if mapping && current.is_a?(TracedString)
            # Exact mappers stamp the filter name onto every carried origin
            # themselves, so pass unstamped origins here.
            map_exact(name, mapping, current, result, args, input_origins)
          else
            wrap_entire(result, with_filters(input_origins, name))
          end
        when Array
          origins = with_filters(input_origins, name)
          result.map do |item|
            item.is_a?(String) && !item.is_a?(TracedString) ? wrap_entire(item, origins) : item
          end
        else
          TracedBox.new(result, with_filters(input_origins, name))
        end
      end

      def with_filters(origins, name)
        return origins if name.nil?

        origins.map { |origin| origin.dup.add_filter(name) }
      end

      def collect_origins(value)
        case value
        when TracedString
          value.trace_nodes.flat_map { |_start, _length, origins| origins }
        when TracedBox
          value.origins
        when Array
          value.flat_map { |item| collect_origins(item) }
        else
          []
        end
      end

      def unwrap(value)
        case value
        when TracedString
          String.new(value)
        when TracedBox
          unwrap(value.value)
        when Array
          value.map { |item| unwrap(item) }
        else
          value
        end
      end

      def deep_unwrap(value)
        case value
        when TracedString
          String.new(value)
        when TracedBox
          deep_unwrap(value.value)
        when Array
          value.map { |item| deep_unwrap(item) }
        when Hash
          value.transform_values { |item| deep_unwrap(item) }
        else
          value
        end
      end

      def wrap_entire(string, origins)
        return string if string.nil? || string.empty?

        origins = origins.reject(&:nil?)
        string = String.new(string) unless string.instance_of?(String)
        TracedString.create(string, [[0, string.bytesize, origins]])
      end

      # --- exact filter mappings ------------------------------------------

      def map_exact(name, kind, input, result, args, fallback_origins)
        nodes =
          case kind
          when :char_identity
            char_identity_nodes(input, result, fallback_origins)
          when :slice
            slice_nodes(input, result, args, fallback_origins)
          when :trim, :ltrim, :rtrim
            trim_nodes(kind, input, result, fallback_origins)
          when :truncate
            truncate_nodes(input, result, args, fallback_origins)
          when :append, :prepend
            concat_nodes(kind, input, result, args)
          else
            [[0, result.bytesize, fallback_origins]]
          end

        stamp(nodes, name)
        TracedString.create(String.new(result), nodes)
      end

      # Every origin carried through an exact mapping records that filter in
      # its chain.
      def stamp(nodes, name)
        nodes.each do |_start, _length, origins|
          origins.map! { |origin| origin.dup.add_filter(name) }
        end
      end

      # Case conversion: byte layout is identical when the byte length is
      # unchanged; otherwise the mapping is not character exact.
      def char_identity_nodes(input, result, fallback_origins)
        return copy_nodes(input) if result.bytesize == String.new(input).bytesize

        [[0, result.bytesize, fallback_origins]]
      end

      def slice_nodes(input, result, args, fallback_origins)
        str = String.new(input)
        return [[0, result.bytesize, fallback_origins]] if str.empty? || result.empty?

        offset = Liquid::Utils.to_integer(unwrap(args[0]))
        start_char = offset >= 0 ? offset : str.length + offset
        return [[0, result.bytesize, fallback_origins]] if start_char < 0 || start_char >= str.length

        byte_start = char_byte_offset(str, start_char)
        nodes = select_nodes(input.trace_nodes, byte_start, result.bytesize)
        nodes.empty? ? [[0, result.bytesize, fallback_origins]] : nodes
      end

      def trim_nodes(kind, input, result, fallback_origins)
        str = String.new(input)
        left_chars = kind == :rtrim ? 0 : str.length - str.lstrip.length
        right_chars = kind == :ltrim ? 0 : str.length - str.rstrip.length
        byte_start = char_byte_offset(str, left_chars)
        byte_length = char_byte_offset(str, str.length - right_chars) - byte_start
        nodes = select_nodes(input.trace_nodes, byte_start, byte_length)
        nodes.empty? && !result.empty? ? [[0, result.bytesize, fallback_origins]] : nodes
      end

      def truncate_nodes(input, result, args, fallback_origins)
        str = String.new(input)
        length = args[0].nil? ? 50 : Liquid::Utils.to_integer(unwrap(args[0]))
        return copy_nodes(input) if str.length <= length

        suffix_raw = args[1].nil? ? '...' : Liquid::Utils.to_s(unwrap(args[1]))
        kept_chars = length - suffix_raw.length
        kept_chars = 0 if kept_chars < 0
        kept_bytes = char_byte_offset(str, kept_chars)

        nodes = select_nodes(input.trace_nodes, 0, kept_bytes)
        unless suffix_raw.empty?
          suffix_origins = argument_origins(args[1])
          suffix_origins << Origin.new(source: :literal, markup: '...') if suffix_origins.empty?
          nodes << [kept_bytes, suffix_raw.bytesize, suffix_origins]
        end
        nodes
      end

      def concat_nodes(kind, input, result, args)
        added_raw = Liquid::Utils.to_s(unwrap(args[0]))
        nodes = copy_nodes(input)
        added_origins = argument_origins(args[0])
        added_origins << Origin.new(source: :filter_argument) if added_origins.empty?

        if kind == :prepend
          # Shift existing content right first, then place the added part at 0
          shift = added_raw.bytesize
          nodes = nodes.map { |start, length, origins| [start + shift, length, origins] }
          nodes << [0, added_raw.bytesize, added_origins] unless added_raw.empty?
        elsif !added_raw.empty?
          nodes << [String.new(input).bytesize, added_raw.bytesize, added_origins]
        end
        nodes
      end

      # Origins carried by a filter argument (a variable argument keeps the
      # provenance of its own expression).
      def argument_origins(arg)
        case arg
        when TracedString
          arg.trace_nodes.flat_map { |_start, _length, origins| origins.map(&:dup) }
        when TracedBox
          arg.origins.map(&:dup)
        else
          []
        end
      end

      # Copy input nodes covering the byte range [byte_start, byte_start +
      # byte_length), re-based at zero.
      def select_nodes(nodes, byte_start, byte_length)
        selected = []
        nodes.each do |seg_start, seg_length, origins|
          overlap_start = [seg_start, byte_start].max
          overlap_finish = [seg_start + seg_length, byte_start + byte_length].min
          next if overlap_start >= overlap_finish

          selected << [
            overlap_start - byte_start,
            overlap_finish - overlap_start,
            origins.map(&:dup),
          ]
        end
        selected
      end

      def copy_nodes(input)
        input.trace_nodes.map { |start, length, origins| [start, length, origins.map(&:dup)] }
      end

      def char_byte_offset(str, char_index)
        return 0 if char_index <= 0

        str.each_char.first(char_index).sum(0, &:bytesize)
      end
    end

    # Result of a traced render: answers provenance queries over byte ranges
    # of the final output.
    class SourceMap
      include Enumerable

      # Byte range [start, finish) with the origins that produced it. The same
      # source value emitted twice shows up as two separate Spans.
      Span = Struct.new(:start, :finish, :origins) do
        def to_h
          { start: start, finish: finish, origins: origins.map(&:to_h) }
        end
      end

      def initialize(nodes, byte_size, template_name = nil)
        @nodes = (nodes || []).sort_by { |start, _length, _origins| start }
        @byte_size = byte_size
        @template_name = template_name
      end

      # Every recorded span, optionally restricted to those intersecting the
      # byte range [start, start + length). Spans are never merged: querying a
      # range containing two outputs of the same value returns both.
      def spans(start = 0, length = nil)
        finish = length ? start + length : @byte_size
        @nodes.filter_map do |seg_start, seg_length, origins|
          next unless seg_start < finish && seg_start + seg_length > start

          Span.new(seg_start, seg_start + seg_length, origins)
        end
      end

      # Origins contributing to a single byte or byte range. When the range
      # spans several spans, all contributing origins are returned.
      def origins_at(offset, length = 1)
        spans(offset, length).flat_map(&:origins).uniq
      end

      def each(&block)
        spans.each(&block)
      end

      def to_a
        spans.map(&:to_h)
      end
    end
  end
end
