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
  # @liquid_optional_param stream [untyped] Consume the collection lazily, one item at a time,
  #   without buffering it. Intended for large or one-shot enumerables. `forloop.length`,
  #   `forloop.rindex`, and `forloop.rindex0` are unavailable (`nil`) in this mode, and
  #   `reversed` cannot be used.
  class For < Block
    Syntax = /\A(#{VariableSegment}+)\s+in\s+(#{QuotedFragment}+)((?:\s+(?:reversed|stream))*)/o

    attr_reader :collection_name, :variable_name, :limit, :from

    def initialize(tag_name, markup, options)
      super
      @from = @limit = nil
      @stream = false
      parse_with_selected_parser(markup)
      if @reversed && @stream
        raise SyntaxError, options[:locale].t("errors.syntax.for_stream_reversed")
      end
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
      if @stream
        render_stream(context, output)
        return output
      end

      segment = collection_segment(context)

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
        keywords         = Regexp.last_match(3).to_s.split
        @reversed        = keywords.include?('reversed')
        @stream          = keywords.include?('stream')
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
      @reversed = false
      @stream   = false
      loop do
        if !@reversed && p.id?('reversed')
          @reversed = true
        elsif !@stream && p.id?('stream')
          @stream = true
        else
          break
        end
      end

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

    # Streaming mode: the collection is consumed lazily, one item at a time,
    # without ever being buffered, sized, or rewound. A single item of
    # lookahead is kept so that `forloop.last` can be answered.
    def render_stream(context, output)
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
      remaining = limit_value.nil? ? nil : Utils.to_integer(limit_value)

      enumerator = stream_enumerator(collection)

      # Apply the offset by discarding items instead of buffering them.
      skipped = 0
      while skipped < from
        begin
          enumerator.next
          skipped += 1
        rescue StopIteration
          break
        end
      end

      rendered  = 0
      for_stack = context.registers[:for_stack] ||= []

      context.stack do
        loop_vars = Liquid::StreamingForloopDrop.new(@name, for_stack[-1])

        for_stack.push(loop_vars)

        begin
          context['forloop'] = loop_vars

          # One item of lookahead, so that `forloop.last` can be answered
          # without knowing the total length of the collection.
          pending      = nil
          have_pending = false
          unless remaining && remaining <= 0
            begin
              pending      = enumerator.next
              have_pending = true
            rescue StopIteration
              # The collection is empty, or the offset consumed it entirely.
            end
          end

          while have_pending
            item = pending

            if remaining == 1
              # The limit makes this the last iteration, so there is no
              # need to read any further.
              pending      = nil
              have_pending = false
            else
              begin
                pending = enumerator.next
              rescue StopIteration
                pending      = nil
                have_pending = false
              end
            end
            remaining -= 1 if remaining

            loop_vars.send(:last=, !have_pending)

            context[@variable_name] = item
            @for_block.render_to_output_buffer(context, output)
            rendered += 1
            loop_vars.send(:increment!)

            # Handle any interrupts if they exist.
            next unless context.interrupt?
            interrupt = context.pop_interrupt
            break if interrupt.is_a?(BreakInterrupt)
          end
        ensure
          for_stack.pop
        end
      end

      offsets[@name] = from + rendered

      render_else(context, output) if rendered.zero?

      output
    end

    def stream_enumerator(collection)
      if collection.is_a?(String)
        # Maintains Ruby 1.8.7 String#each behaviour on 1.9
        collection.empty? ? [].each : [collection].each
      elsif collection.is_a?(Enumerator)
        collection
      elsif collection.respond_to?(:each)
        collection.to_enum(:each)
      else
        [].each
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
