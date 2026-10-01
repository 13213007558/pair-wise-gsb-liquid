# frozen_string_literal: true

module Liquid
  # @liquid_public_docs
  # @liquid_type tag
  # @liquid_category iteration
  # @liquid_name for
  # @liquid_summary
  #   Renders an expression for every item in an array.
  # @liquid_description
  #   You can do a maximum of 50 iterations with a `for` loop. If you need to iterate over more than 50 items, then use the
  #   [`paginate` tag](/docs/api/liquid/tags/paginate) to split the items over multiple pages.
  #
  #   > Tip:
  #   > Every `for` loop has an associated [`forloop` object](/docs/api/liquid/objects/forloop) with information about the loop.
  # @liquid_syntax
  #   {% for variable in array %}
  #     expression
  #   {% endfor %}
  # @liquid_syntax_keyword variable The current item in the array.
  # @liquid_syntax_keyword array The array to iterate over.
  # @liquid_syntax_keyword expression The expression to render for each iteration.
  # @liquid_optional_param limit: [number] The number of iterations to perform.
  # @liquid_optional_param offset: [number] The 1-based index to start iterating at.
  # @liquid_optional_param stream: [boolean] Iterate without buffering the collection.
  # @liquid_optional_param range [untyped] A custom numeric range to iterate over.
  # @liquid_optional_param reversed [untyped] Iterate in reverse order.
  class For < Block
    Syntax = /\A(#{VariableSegment}+)\s+in\s+(#{QuotedFragment}+)\s*(reversed)?/o

    attr_reader :collection_name, :variable_name, :limit, :from, :stream

    def initialize(tag_name, markup, options)
      super
      @from = @limit = nil
      @stream = nil
      parse_with_selected_parser(markup)
      @for_block = new_body
      @else_block = nil
    end

    def parse(tokens)
      if parse_body(@for_block, tokens)
        parse_body(@else_block, tokens)
      end
      if blank?
        @else_block&.remove_blank_strings
        @for_block.remove_blank_strings
      end
      @else_block&.freeze
      @for_block.freeze
    end

    def nodelist
      @else_block ? [@for_block, @else_block] : [@for_block]
    end

    def unknown_tag(tag, markup, tokens)
      return super unless tag == 'else'
      @else_block = new_body
    end

    def render_to_output_buffer(context, output)
      return render_stream_to_output_buffer(context, output) if stream_enabled?(context)

      segment = collection_segment(context)

      if segment.empty?
        render_else(context, output)
      else
        render_segment(context, output, segment)
      end

      output
    end

    private

    STREAM_END = Object.new.freeze

    class StreamCursor
      attr_reader :length, :position

      def self.create(collection, from, to, resource_limits)
        cursor = allocate
        cursor.send(:initialize_stream, collection, from, to, resource_limits)
        cursor
      end

      def source?(collection)
        collection.equal?(@source)
      end

      def self.length_for(collection, from, to)
        if collection.instance_of?(Range) &&
            collection.begin.is_a?(Integer) &&
            collection.end.is_a?(Integer)
          RangeSlice.new(collection, from, to, ResourceLimits.new({})).length
        elsif collection.is_a?(Array) || collection.is_a?(Hash)
          finite_bounded_length(collection.length, from, to)
        elsif collection.is_a?(String)
          from.zero? && (to.nil? || to.positive?) ? 1 : 0
        elsif collection.is_a?(Enumerator)
          size = collection.size
          finite_bounded_length(size, from, to) if size.is_a?(Integer)
        else
          nil
        end
      end

      def self.finite_bounded_length(total, from, to)
        return nil unless total.is_a?(Integer) && total >= 0

        finish = to || total
        [finish - from, 0].max
      end
      private_class_method :finite_bounded_length

      def peek
        return false if @eof

        unless @read
          begin
            @next = @enumerator.next
            @resource_limits.increment_render_score(1) if @charge_items
          rescue StopIteration
            @eof = true
            @next = STREAM_END
          end
          @read = true
        end

        !@eof
      end

      def peek_next
        unless @lookahead_read
          begin
            @lookahead = @enumerator.next
            @resource_limits.increment_render_score(1) if @charge_items
          rescue StopIteration
            @lookahead_eof = true
          end
          @lookahead_read = true
        end

        !@lookahead_eof
      end

      def current
        raise StopIteration unless peek
        @next
      end

      def advance
        @position += 1

        if @lookahead_read
          @read = !@lookahead_eof
          @eof = @lookahead_eof
          @next = @lookahead_eof ? STREAM_END : @lookahead
        else
          @read = false
          @next = STREAM_END
        end

        @lookahead = STREAM_END
        @lookahead_read = false
        @lookahead_eof = false
      end

      def take
        item = current
        advance
        item
      end

      private

      def initialize_stream(collection, from, to, resource_limits)
        @source = collection
        @resource_limits = resource_limits
        @position = from
        @read = false
        @eof = false
        @next = STREAM_END
        @lookahead = STREAM_END
        @lookahead_read = false
        @lookahead_eof = false
        @charge_items = true
        @length = nil

        @enumerator =
          if integer_range?(collection)
            slice = RangeSlice.new(collection, from, to, resource_limits)
            @length = slice.length
            @charge_items = false
            slice.to_enum(:each)
          elsif collection.is_a?(Array)
            @length = self.class.length_for(collection, from, to)
            @charge_items = false
            collection.to_enum(:each)
          elsif collection.is_a?(Hash)
            @length = self.class.length_for(collection, from, to)
            collection.to_enum(:each)
          elsif collection.is_a?(String)
            @length = self.class.length_for(collection, from, to)
            @charge_items = false
            string_enumerator(collection)
          elsif collection.is_a?(Enumerator)
            @length = self.class.length_for(collection, from, to)
            collection.to_enum(:each)
          elsif collection.respond_to?(:each)
            collection.to_enum(:each)
          else
            @length = 0
            @charge_items = false
            @eof = true
            empty_enumerator
          end

        skip_offset(from)
      end

      def skip_offset(offset)
        return if integer_range?(@source)

        offset.times do
          break unless peek

          take
        end
      end

      def integer_range?(collection)
        collection.is_a?(Range) &&
          collection.instance_of?(Range) &&
          collection.begin.is_a?(Integer) &&
          collection.end.is_a?(Integer)
      end

      def string_enumerator(string)
        Enumerator.new { |yielder| yielder << string }
      end

      def empty_enumerator
        Enumerator.new {}
      end
    end

    private_constant :StreamCursor

    protected

    def lax_parse(markup)
      if markup =~ Syntax
        @variable_name   = Regexp.last_match(1)
        collection_name  = Regexp.last_match(2)
        @reversed        = !!Regexp.last_match(3)
        @name            = "#{@variable_name}-#{collection_name}"
        @collection_name = parse_expression(collection_name)
        attributes_markup = Regexp.last_match.post_match
        bare_stream = attributes_markup =~ /(?<![\w-])stream(?:ing)?\b(?!\s*:)/
        @stream = nil
        markup.scan(TagAttributes) do |key, value|
          set_attribute(key, value)
        end
        @stream = true if bare_stream && @stream.nil?
      else
        raise SyntaxError, options[:locale].t("errors.syntax.for")
      end
    end

    def strict_parse(markup)
      p = @parse_context.new_parser(markup)
      @variable_name = p.consume(:id)
      raise SyntaxError, options[:locale].t("errors.syntax.for_invalid_in") unless p.id?('in')

      collection_name  = p.expression
      @collection_name = parse_expression(collection_name, safe: true)

      @name     = "#{@variable_name}-#{collection_name}"
      @reversed = p.id?('reversed')

      while p.look(:comma) || p.look(:id)
        p.consume?(:comma)
        unless (attribute = p.id?('limit') || p.id?('offset') || p.id?('stream') || p.id?('streaming'))
          raise SyntaxError, options[:locale].t("errors.syntax.for_invalid_attribute")
        end

        if attribute == 'stream' || attribute == 'streaming'
          if p.look(:colon)
            p.consume(:colon)
            @stream = parse_expression(p.expression, safe: true)
          else
            @stream = true
          end
        else
          p.consume(:colon)
          set_attribute(attribute, p.expression, safe: true)
        end
      end
      p.consume(:end_of_string)
    end

    private

    def strict2_parse(markup)
      strict_parse(markup)
    end

    def stream_enabled?(context)
      return false if @stream.nil?

      value = context.evaluate(@stream)
      !value.nil? && value != false
    end

    def render_stream_to_output_buffer(context, output)
      raise ArgumentError, "reversed is not supported in streaming for loops" if @reversed

      for_stack = context.registers[:for_stack] ||= []
      nested = !for_stack.empty?
      shadowed = for_stack.any? { |loop_vars| loop_vars.name == @name }
      offsets = stream_offsets(context)
      cursors = stream_cursors(context)
      saved_offset = offsets[@name] if shadowed
      saved_cursor = cursors[@name] if shadowed

      begin
        from =
          if @from == :continue
            shadowed ? 0 : offsets[@name].to_i
          else
            from_value = context.evaluate(@from)
            from_value.nil? ? 0 : Utils.to_integer(from_value)
          end

        raise ArgumentError, "negative offset is not supported in streaming for loops" if from.negative?

        limit_value = context.evaluate(@limit)
        limit = limit_value.nil? ? nil : Utils.to_integer(limit_value)
        collection = context.evaluate(@collection_name)
        known_length = StreamCursor.length_for(collection, from, limit && from + limit)

        if known_length.nil? && stream_block_uses_unknown_length_metadata?(@for_block, {})
          raise ArgumentError, "forloop length metadata is not supported by streaming for loops with unknown length"
        end

        to = limit && from + limit
        cursor = stream_cursor(context, collection, from, to, nested)
        if limit && !limit.positive?
          offsets[@name] = cursor.position
          render_else(context, output)
          return output
        end

        render_stream_segment(context, output, cursor, from, limit)
      ensure
        if shadowed
          offsets[@name] = saved_offset
          cursors[@name] = saved_cursor
        end
      end

      output
    end

    def stream_offsets(context)
      context.registers[:for_stream_offsets] ||= {}
    end

    def stream_cursors(context)
      context.registers[:for_stream_cursors] ||= {}
    end

    def stream_cursor(context, collection, from, to, nested)
      cursors = stream_cursors(context)
      existing = cursors[@name]

      if !nested && existing&.source?(collection) && existing.position == from
        existing
      else
        StreamCursor.create(collection, from, to, context.resource_limits)
      end
    end

    def stream_block_uses_unknown_length_metadata?(node, visited)
      key = node.object_id
      return false if visited.key?(key)

      visited[key] = true

      if node.is_a?(VariableLookup) && node.name == 'forloop'
        return %w[length rindex rindex0].include?(node.lookups.first)
      end

      return false if node.is_a?(String)

      return false if node.is_a?(Liquid::For)

      children =
        if !node.is_a?(String) && node.respond_to?(:nodelist)
          Array(node.nodelist)
        else
          ParseTreeVisitor.for(node).children
        end
      children.any? { |child| stream_block_uses_unknown_length_metadata?(child, visited) }
    end

    def render_stream_segment(context, output, cursor, from, limit)
      offsets = stream_offsets(context)
      cursors = stream_cursors(context)
      for_stack = context.registers[:for_stack] ||= []
      cursors[@name] = cursor

      unless cursor.peek
        offsets[@name] = from
        render_else(context, output)
        return
      end

      context.stack do
        rendered = 0
        loop_vars = Liquid::ForloopDrop.new(@name, cursor.length, for_stack[-1]) do
          if limit && loop_vars.index >= limit
            true
          else
            !cursor.peek_next
          end
        end

        for_stack.push(loop_vars)

        begin
          context['forloop'] = loop_vars

          while (limit.nil? || rendered < limit) && cursor.peek
            context[@variable_name] = cursor.current
            rendered += 1

            @for_block.render_to_output_buffer(context, output)
            loop_vars.send(:increment!)
            cursor.advance

            next unless context.interrupt?

            interrupt = context.pop_interrupt
            if interrupt.is_a?(BreakInterrupt)
              if limit
                while rendered < limit
                  break unless cursor.peek

                  cursor.take
                  rendered += 1
                end
              end
              break
            end
            next if interrupt.is_a?(ContinueInterrupt)
          end
        ensure
          for_stack.pop
          offsets[@name] = cursor.position
        end
      end
    end

    def collection_segment(context)
      offsets = context.registers[:for] ||= {}

      from = if @from == :continue
        offsets[@name].to_i
      else
        from_value = context.evaluate(@from)
        if from_value.nil?
          0
        else
          Utils.to_integer(from_value)
        end
      end

      collection = context.evaluate(@collection_name)

      limit_value = context.evaluate(@limit)
      to = if limit_value.nil?
        nil
      else
        Utils.to_integer(limit_value) + from
      end

      segment = Utils.slice_collection_for_iteration(
        collection, from, to, context.resource_limits, use_range_to_a: true
      )
      segment.reverse! if @reversed

      offsets[@name] = from + segment.length

      segment
    end

    def render_segment(context, output, segment)
      for_stack = context.registers[:for_stack] ||= []
      length    = segment.length

      context.stack do
        loop_vars = Liquid::ForloopDrop.new(@name, length, for_stack[-1])

        for_stack.push(loop_vars)

        begin
          context['forloop'] = loop_vars

          segment.each do |item|
            context[@variable_name] = item
            @for_block.render_to_output_buffer(context, output)
            loop_vars.send(:increment!)

            # Handle any interrupts if they exist.
            next unless context.interrupt?
            interrupt = context.pop_interrupt
            break if interrupt.is_a?(BreakInterrupt)
            next if interrupt.is_a?(ContinueInterrupt)
          end
        ensure
          for_stack.pop
        end
      end

      output
    end

    def set_attribute(key, expr, safe: false)
      case key
      when 'offset'
        @from = if expr == 'continue'
          :continue
        else
          parse_expression(expr, safe: safe)
        end
      when 'limit'
        @limit = parse_expression(expr, safe: safe)
      when 'stream', 'streaming'
        @stream = parse_expression(expr, safe: safe)
      end
    end

    def render_else(context, output)
      if @else_block
        @else_block.render_to_output_buffer(context, output)
      else
        output
      end
    end

    class ParseTreeVisitor < Liquid::ParseTreeVisitor
      def children
        (super + [@node.limit, @node.from, @node.collection_name]).compact
      end
    end
  end
end
