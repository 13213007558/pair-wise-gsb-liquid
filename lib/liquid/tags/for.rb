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
  #
  #   A loop may declare a `label`, which lets an inner `{% break label %}` or
  #   `{% continue label %}` target this loop directly instead of the innermost one.
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
  # @liquid_optional_param label: [string] A label that `break` and `continue` can target.
  class For < Block
    Syntax = /\A(#{VariableSegment}+)\s+in\s+(#{QuotedFragment}+)\s*(reversed)?/o

    LabelSyntax = /\A[a-zA-Z_][\w\-]*\z/

    attr_reader :collection_name, :variable_name, :limit, :from, :label

    def initialize(tag_name, markup, options)
      super
      @from = @limit = @label = nil
      parse_with_selected_parser(markup)
      @for_block = new_body
      @else_block = nil
    end

    def parse(tokens)
      push_label_scope
      begin
        if parse_body(@for_block, tokens)
          parse_body(@else_block, tokens)
        end
        if blank?
          @else_block&.remove_blank_strings
          @for_block.remove_blank_strings
        end
        @else_block&.freeze
        @for_block.freeze
      ensure
        pop_label_scope
      end
    end

    def nodelist
      @else_block ? [@for_block, @else_block] : [@for_block]
    end

    def unknown_tag(tag, markup, tokens)
      return super unless tag == 'else'
      @else_block = new_body
    end

    def render_to_output_buffer(context, output)
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
        unless (attribute = p.id?('limit') || p.id?('offset') || p.id?('label'))
          raise SyntaxError, options[:locale].t("errors.syntax.for_invalid_attribute")
        end
        p.consume(:colon)
        if attribute == 'label'
          set_attribute(attribute, p.consume(:id), safe: true)
        else
          set_attribute(attribute, p.expression, safe: true)
        end
      end
      p.consume(:end_of_string)
    end

    private

    def strict2_parse(markup)
      strict_parse(markup)
    end

    # Loop labels are resolved lexically: while this loop's body is parsed,
    # its label is visible to nested {% break %}/{% continue %} tags.
    def push_label_scope
      return unless @label

      stack = parse_context.for_label_stack
      if stack.include?(@label)
        raise SyntaxError, options[:locale].t("errors.syntax.for_duplicate_label", label: @label)
      end
      stack.push(@label)
      @label_scope_pushed = true
    end

    def pop_label_scope
      parse_context.for_label_stack.pop if @label_scope_pushed
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

            if labeled_interrupt?(interrupt) && interrupt.label != @label
              # The interrupt targets an enclosing loop. Stop iterating and
              # re-queue the interrupt so the loop carrying that label (or
              # the error handler, if there is none) can handle it.
              context.push_interrupt(interrupt)
              break
            end

            break if interrupt.is_a?(BreakInterrupt)
            next if interrupt.is_a?(ContinueInterrupt)
          end
        ensure
          for_stack.pop
        end
      end

      output
    end

    def labeled_interrupt?(interrupt)
      interrupt.respond_to?(:label) && !interrupt.label.nil?
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
      when 'label'
        unless expr.is_a?(String) && expr.match?(LabelSyntax)
          raise SyntaxError, options[:locale].t("errors.syntax.for_invalid_label", label: expr)
        end
        @label = expr
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
