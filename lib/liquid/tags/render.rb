# frozen_string_literal: true

module Liquid
  # @liquid_public_docs
  # @liquid_type tag
  # @liquid_category theme
  # @liquid_name render
  # @liquid_summary
  #   Renders a [snippet](/themes/architecture/snippets) or [app block](/themes/architecture/sections/section-schema#render-app-blocks).
  # @liquid_description
  #   Inside snippets and app blocks, you can't directly access variables that are [created](/docs/api/liquid/tags/variable-tags) outside
  #   of the snippet or app block. However, you can [specify variables as parameters](/docs/api/liquid/tags/render#render-passing-variables-to-a-snippet)
  #   to pass outside variables to snippets.
  #
  #   While you can't directly access created variables, you can access global objects, as well as any objects that are
  #   directly accessible outside the snippet or app block. For example, a snippet or app block inside the [product template](/themes/architecture/templates/product)
  #   can access the [`product` object](/docs/api/liquid/objects/product), and a snippet or app block inside a [section](/themes/architecture/sections)
  #   can access the [`section` object](/docs/api/liquid/objects/section).
  #
  #   Outside a snippet or app block, you can't access variables created inside the snippet or app block.
  #
  #   A render call can also provide named content [slots](/docs/api/liquid/tags/render#slots)
  #   using a block form:
  #
  #   ```liquid
  #   {% render 'card', title: product.title %}
  #     {% slot actions %}<button>Buy</button>{% endslot %}
  #   {% endrender %}
  #   ```
  #
  #   The snippet renders supplied slots with the `slot` tag; slots that the
  #   caller doesn't provide fall back to the tag's default content.
  #
  #   > Note:
  #   > When you render a snippet using the `render` tag, you can't use the [`include` tag](/docs/api/liquid/tags/include)
  #   > inside the snippet.
  # @liquid_syntax
  #   {% render 'filename' %}
  # @liquid_syntax_keyword filename The name of the snippet to render, without the `.liquid` extension.
  class Render < Block
    FOR = 'for'
    SYNTAX = /(#{QuotedString}+)(\s+(with|#{FOR})\s+(#{QuotedFragment}+))?(\s+(?:as)\s+(#{VariableSegment}+))?/o

    disable_tags "include"

    attr_reader :template_name_expr, :variable_name_expr, :attributes, :alias_name, :slots, :body

    def initialize(tag_name, markup, options)
      super
      @slots = {}
      parse_with_selected_parser(markup)
    end

    def for_loop?
      @is_for_loop
    end

    def parse(tokens)
      return unless parse_block_form?(tokens)

      @body = new_body
      while parse_body(@body, tokens)
      end
      build_slots
      @body.freeze
    end

    def nodelist
      block_form? ? [@body] : Const::EMPTY_ARRAY
    end

    def block_form?
      !!@has_block
    end

    # Render tags are never blank, so errors raised while rendering a partial
    # aren't suppressed by BlockBody's blank-tag error handling.
    def blank?
      false
    end

    # A render block may only contain `slot` blocks. Any other end tag (e.g.
    # an `endif` left over from a tag that isn't allowed here) is a syntax
    # error.
    def unknown_tag(tag, _markup, _tokens)
      return super if tag == block_delimiter
      raise slots_only_error
    end

    def render_to_output_buffer(context, output)
      render_partial(context, output)
    end

    def render_partial(context, output)
      # The expression should be a String literal, which parses to a String object
      template_name = @template_name_expr
      raise ::ArgumentError unless template_name.is_a?(String)

      partial = PartialCache.load(
        template_name,
        context: context,
        parse_context: parse_context,
      )

      context_variable_name = @alias_name || template_name.split('/').last

      render_partial_func = ->(var, forloop) {
        inner_context               = context.new_isolated_subcontext
        inner_context.template_name = partial.name
        inner_context.partial       = true
        inner_context['forloop']    = forloop if forloop

        bindings = {}
        @attributes.each do |key, value|
          evaluated = context.evaluate(value)
          inner_context[key] = evaluated
          bindings[key] = evaluated
        end
        inner_context[context_variable_name] = var unless var.nil?
        bindings[context_variable_name] = var unless var.nil?
        bindings['forloop'] = forloop if forloop

        own_frame = @slots.transform_values do |body|
          SlotInvocation.new(body, context, bindings)
        end

        # Forward enclosing slots and push this render's own frame on top, so
        # nested snippets can either render caller supplied content or override
        # individual slots with their own blocks.
        inner_context.slots = (context.slots || SlotStack.new).for_render(
          own_frame, bindings
        )

        partial.render_to_output_buffer(inner_context, output)
        forloop&.send(:increment!)
      }

      variable = @variable_name_expr ? context.evaluate(@variable_name_expr) : nil
      if @is_for_loop && variable.respond_to?(:each) && variable.respond_to?(:count)
        forloop = Liquid::ForloopDrop.new(template_name, variable.count, nil)
        variable.each { |var| render_partial_func.call(var, forloop) }
      else
        render_partial_func.call(variable, nil)
      end

      output
    end

    # render (string) (with|for expression)? (as id)? (key: value)*
    def strict2_parse(markup)
      p = @parse_context.new_parser(markup)

      @template_name_expr = parse_expression(strict2_template_name(p), safe: true)
      with_or_for         = p.id?("for") || p.id?("with")
      @variable_name_expr = safe_parse_expression(p) if with_or_for
      @alias_name         = p.consume(:id) if p.id?("as")
      @is_for_loop        = (with_or_for == FOR)

      p.consume?(:comma)

      @attributes = {}
      while p.look(:id)
        key = p.consume
        p.consume(:colon)
        @attributes[key] = safe_parse_expression(p)
        p.consume?(:comma)
      end

      p.consume(:end_of_string)
    end

    def strict2_template_name(p)
      p.consume(:string)
    end

    def strict_parse(markup)
      lax_parse(markup)
    end

    def lax_parse(markup)
      raise SyntaxError, options[:locale].t("errors.syntax.render") unless markup =~ SYNTAX

      template_name = Regexp.last_match(1)
      with_or_for = Regexp.last_match(3)
      variable_name = Regexp.last_match(4)

      @alias_name = Regexp.last_match(6)
      @variable_name_expr = variable_name ? parse_expression(variable_name) : nil
      @template_name_expr = parse_expression(template_name)
      @is_for_loop = (with_or_for == FOR)

      @attributes = {}
      markup.scan(TagAttributes) do |key, value|
        @attributes[key] = parse_expression(value)
      end
    end

    class ParseTreeVisitor < Liquid::ParseTreeVisitor
      def children
        [
          @node.template_name_expr,
          @node.variable_name_expr,
        ] + @node.attributes.values + (@node.block_form? ? [@node.body] : Const::EMPTY_ARRAY)
      end
    end

    private

    # A render call has a block (and therefore slots) when the first top level
    # tag that follows the opening tag is a `slot` tag or an immediate
    # `endrender` delimiter (an empty block simply provides no slots). Tags
    # nested inside other blocks (e.g. an `if`) don't count. The check is a pure
    # look ahead and consumes nothing.
    def parse_block_form?(tokens)
      @has_block ||= begin
        depth = 0
        offset = 0
        first_top_level_tag = nil
        while (token = tokens.peek(offset))
          if (name = token_tag_name(token, tokens.for_liquid_tag))
            # This token begins with a tag.
            if depth.zero?
              first_top_level_tag = name
              break
            elsif name.start_with?('end')
              depth -= 1
            elsif block_tag_name?(name)
              depth += 1
            end
          elsif depth.zero? && token.strip.empty?
            # Leading whitespace before the first tag is harmless and gets
            # skipped so that a block can start on the following line.
          elsif depth.zero?
            # The first top level content is text (or a variable), not a tag:
            # this is a self closing render. No need to scan any further.
            break
          end
          offset += 1
        end
        first_top_level_tag == 'slot' || first_top_level_tag == 'endrender'
      end
    end

    def block_tag_name?(name)
      tag_class = parse_context.environment.tag_for_name(name)
      tag_class && tag_class.ancestors.include?(Block)
    end

    def token_tag_name(token, for_liquid_tag)
      regexp = for_liquid_tag ? BlockBody::LiquidTagToken : BlockBody::FullToken
      match = regexp.match(token)
      return unless match
      for_liquid_tag ? match[1] : match[2]
    end

    def build_slots
      @body.nodelist.each do |node|
        if node.is_a?(String)
          next if node.strip.empty?
          raise slots_only_error
        elsif !node.is_a?(Slot)
          raise slots_only_error
        elsif @slots.key?(node.slot_name)
          raise SyntaxError, parse_context.locale.t(
            "errors.syntax.render_duplicate_slot", slot: node.slot_name
          )
        else
          @slots[node.slot_name] = node.slot_body
        end
      end
    end

    def slots_only_error
      SyntaxError.new(parse_context.locale.t("errors.syntax.render_slots_only"))
    end
  end
end
