# frozen_string_literal: true

module Liquid
  # @liquid_public_docs
  # @liquid_type tag
  # @liquid_category iteration
  # @liquid_name stream
  # @liquid_summary
  #   Renders an expression for every item in a collection, consuming it lazily.
  # @liquid_description
  #   Unlike the [`for` tag](/docs/api/liquid/tags/for), which buffers the whole
  #   segment before rendering, `stream` pulls one item at a time from the
  #   collection. The collection only needs to respond to `each`; it does not
  #   need to know its size and it is never rewound or converted to an array.
  #   This makes `stream` suitable for large or one-shot enumerables, such as
  #   database cursors.
  #
  #   Because the total number of iterations is unknown, `forloop.length`,
  #   `forloop.rindex`, and `forloop.rindex0` return `nil`. `forloop.last` is
  #   still available: the tag looks one item ahead to detect the end of the
  #   collection. Iterating in reverse is not possible, so the `reversed`
  #   keyword is rejected.
  #
  #   `limit`, `offset` (including `offset:continue`), `break`, `continue`,
  #   and `{% else %}` behave as they do in a `for` loop.
  # @liquid_syntax
  #   {% stream variable in collection %}
  #     expression
  #   {% endstream %}
  # @liquid_syntax_keyword variable The current item in the collection.
  # @liquid_syntax_keyword collection The collection to iterate over. It only needs to respond to `each`.
  # @liquid_syntax_keyword expression The expression to render for each iteration.
  # @liquid_optional_param limit: [number] The number of iterations to perform.
  # @liquid_optional_param offset: [number] The 1-based index to start iterating at.
  class Stream < For
    def render_to_output_buffer(context, output)
      offsets = context.registers[:for] ||= {}

      from = if @from == :continue
        offsets[@name].to_i
      else
        from_value = context.evaluate(@from)
        from_value.nil? ? 0 : Utils.to_integer(from_value)
      end

      limit_value = context.evaluate(@limit)
      limit = limit_value.nil? ? nil : Utils.to_integer(limit_value)

      collection = context.evaluate(@collection_name)
      iterator   = stream_iterator(collection)

      rendered = render_stream(context, output, iterator, from, limit)

      # Record how far iteration advanced so a later `offset:continue` loop
      # resumes after the last rendered item.
      offsets[@name] = from + rendered

      output
    end

    private

    def lax_parse(markup)
      super
      reject_reversed!
    end

    def strict_parse(markup)
      super
      reject_reversed!
    end

    def reject_reversed!
      return unless @reversed
      raise SyntaxError, options[:locale].t("errors.syntax.stream_reversed")
    end

    # Anything responding to #each is consumed lazily through a pull iterator;
    # the collection is never buffered, sized, or rewound. Strings keep the
    # historical `for` behavior of iterating as a single item.
    def stream_iterator(collection)
      if collection.is_a?(String)
        collection.empty? ? [].each : [collection].each
      elsif collection.respond_to?(:each)
        collection.enum_for(:each)
      end
    end

    def render_stream(context, output, iterator, from, limit)
      if iterator.nil? || (limit && limit <= 0)
        render_else(context, output)
        return 0
      end

      resource_limits = context.resource_limits

      # Skip the offset by consuming and discarding items.
      skipped = 0
      while skipped < from
        break unless pull_next(iterator, resource_limits)
        skipped += 1
      end

      has_current, current = pull_next(iterator, resource_limits)
      unless has_current
        render_else(context, output)
        return 0
      end

      rendered = 0
      for_stack = context.registers[:for_stack] ||= []

      context.stack do
        loop_vars = Liquid::ForloopDrop.new(@name, nil, for_stack[-1])
        for_stack.push(loop_vars)

        begin
          context['forloop'] = loop_vars

          loop do
            # Look one item ahead so `forloop.last` is known before rendering.
            # When `limit` caps the loop, the current item is already known to
            # be the last one, so no extra item is pulled.
            if limit && rendered + 1 >= limit
              has_next = false
            else
              has_next, upcoming = pull_next(iterator, resource_limits)
            end
            loop_vars.send(:mark_last!) unless has_next

            context[@variable_name] = current
            @for_block.render_to_output_buffer(context, output)
            rendered += 1
            loop_vars.send(:increment!)

            if context.interrupt?
              interrupt = context.pop_interrupt
              break if interrupt.is_a?(BreakInterrupt)
            end

            break unless has_next
            current = upcoming
          end
        ensure
          for_stack.pop
        end
      end

      rendered
    end

    # Pulls one item, charging the resource limits for the consumed input just
    # like the buffered iteration paths do. Returns [true, item] or [false, nil]
    # once the iterator is exhausted; items themselves may legitimately be nil.
    def pull_next(iterator, resource_limits)
      resource_limits.increment_render_score(1)
      [true, iterator.next]
    rescue StopIteration
      [false, nil]
    end
  end
end
