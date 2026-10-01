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
  # @liquid_optional_param range [untyped] A custom numeric range to iterate over.
  # @liquid_optional_param reversed [untyped] Iterate in reverse order.
  class For < Block
    Syntax = /\A(#{VariableSegment}+)\s+in\s+(#{QuotedFragment}+)\s*(reversed)?/o

    attr_reader :collection_name, :variable_name, :limit, :from

    def initialize(tag_name, markup, options)
      super
      @from = @limit = nil
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
      collection = context.evaluate(@collection_name)

      if streaming_collection?(context, collection)
        render_stream(context, output, collection)
        return output
      end

      segment = collection_segment(context, collection)

      if segment.empty?
        render_else(context, output)
      else
        render_segment(context, output, segment)
      end

      output
    end

    protected

    def lax_parse(markup)
      if markup =~ Syntax
        @variable_name   = Regexp.last_match(1)
        collection_name  = Regexp.last_match(2)
        @reversed        = !!Regexp.last_match(3)
        @name            = "#{@variable_name}-#{collection_name}"
        @collection_name = parse_expression(collection_name)
        markup.scan(TagAttributes) do |key, value|
          set_attribute(key, value)
        end
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
        unless (attribute = p.id?('limit') || p.id?('offset'))
          raise SyntaxError, options[:locale].t("errors.syntax.for_invalid_attribute")
        end
        p.consume(:colon)
        set_attribute(attribute, p.expression, safe: true)
      end
      p.consume(:end_of_string)
    end

    private

    def strict2_parse(markup)
      strict_parse(markup)
    end

    def collection_segment(context, collection)
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

    # Stream-like collections are consumed lazily, one item at a time, so
    # single-read data sources (e.g. enumerators) do not have to be buffered
    # into an array before the first item is rendered. At most one item of
    # lookahead is used, to detect `forloop.last`.
    def streaming_collection?(context, collection)
      return false unless context.environment.streaming_for_loop
      return false if collection.nil?
      # Sized, re-readable collections keep the existing buffered behavior.
      return false if collection.is_a?(Array) || collection.is_a?(Range) ||
        collection.is_a?(String) || collection.is_a?(Hash)

      collection.respond_to?(:each)
    end

    def render_stream(context, output, collection)
      if @reversed
        raise Liquid::ArgumentError, "reversed is not supported when streaming a collection of unknown length"
      end

      offsets          = context.registers[:for] ||= {}
      stream_positions = context.registers[:for_stream_positions] ||= {}

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

      limit_value = context.evaluate(@limit)
      limit = limit_value.nil? ? nil : Utils.to_integer(limit_value)

      # A stream cannot be rewound. When a previous loop with the same name
      # already consumed part of this very object, resume from the position
      # it reached instead of skipping items a second time.
      previous = stream_positions[@name]
      if previous && previous[0].equal?(collection)
        position         = previous[1]
        stream_exhausted = previous[2]
      else
        position         = 0
        stream_exhausted = false
      end

      if stream_exhausted || (limit && limit <= 0)
        offsets[@name] = from
        return render_else(context, output)
      end

      iterator = stream_iterator(collection)
      resource_limits = context.resource_limits
      eof = Object.new
      pulled = 0
      exhausted = false

      pull = lambda do
        item = iterator.next
        resource_limits.increment_render_score(1)
        pulled += 1
        item
      rescue StopIteration
        exhausted = true
        eof
      end

      # Apply the offset by consuming items, skipping only the part of the
      # offset that this object has not already satisfied.
      skip = from - position
      skip = 0 if skip.negative?
      skipped = 0
      while skipped < skip && !exhausted
        pull.call
        skipped += 1 unless exhausted
      end

      current = exhausted ? eof : pull.call

      if current.equal?(eof)
        offsets[@name] = from
        stream_positions[@name] = [collection, position + pulled, true]
        return render_else(context, output)
      end

      render_stream_segment(context, output, current, limit, pull, eof)

      # The continuation offset counts every item taken from the stream,
      # including the single lookahead item, since it cannot be put back.
      offsets[@name] = from + pulled - skipped
      stream_positions[@name] = [collection, position + pulled, exhausted]

      output
    end

    def render_stream_segment(context, output, first_item, limit, pull, eof)
      for_stack = context.registers[:for_stack] ||= []

      context.stack do
        loop_vars = Liquid::StreamingForloopDrop.new(@name, for_stack[-1])

        for_stack.push(loop_vars)

        begin
          context['forloop'] = loop_vars

          current  = first_item
          rendered = 0

          loop do
            # Look ahead at most one item to know whether the current item
            # is the last. Reaching the limit makes the current item last
            # without touching the stream.
            lookahead = if limit && rendered + 1 >= limit
              eof
            else
              pull.call
            end
            is_last = lookahead.equal?(eof)

            loop_vars.send(:last=, is_last)
            context[@variable_name] = current
            @for_block.render_to_output_buffer(context, output)
            loop_vars.send(:increment!)
            rendered += 1

            # Handle any interrupts if they exist.
            if context.interrupt?
              interrupt = context.pop_interrupt
              break if interrupt.is_a?(BreakInterrupt)
            end
            break if is_last

            current = lookahead
          end
        ensure
          for_stack.pop
        end
      end

      output
    end

    def stream_iterator(collection)
      if collection.is_a?(Enumerator)
        # Enumerator#each without a block returns the enumerator itself,
        # preserving its position so pause/resume keeps reading where the
        # previous loop stopped.
        collection.each
      else
        collection.to_enum(:each)
      end
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
