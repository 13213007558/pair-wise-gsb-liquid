# frozen_string_literal: true

require_relative 'slot'

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
  #   > Note:
  #   > When you render a snippet using the `render` tag, you can't use the [`include` tag](/docs/api/liquid/tags/include)
  #   > inside the snippet.
  #
  #   ### Content slots
  #
  #   A render call can optionally use a body ending with `{% endrender %}` to supply named
  #   [slots](/docs/api/liquid/tags/slot) to the snippet:
  #
  #   ```liquid
  #   {% render 'card' %}
  #     {% slot actions %}<a href="/buy">Buy</a>{% endslot %}
  #   {% endrender %}
  #   ```
  #
  #   Slot content is evaluated lazily (only when the snippet renders the slot) in the caller's scope, so it can read
  #   the caller's variables while variables created inside the snippet stay private.
  # @liquid_syntax
  #   {% render 'filename' %}
  # @liquid_syntax_keyword filename The name of the snippet to render, without the `.liquid` extension.
  class Render < Block
    FOR = 'for'
    SYNTAX = /(#{QuotedString}+)(\s+(with|#{FOR})\s+(#{QuotedFragment}+))?(\s+(?:as)\s+(#{VariableSegment}+))?/o

    disable_tags "include"

    attr_reader :template_name_expr, :variable_name_expr, :attributes, :alias_name, :slots

    def initialize(tag_name, markup, options)
      super
      parse_with_selected_parser(markup)
    end

    def for_loop?
      @is_for_loop
    end

    def blank?
      false
    end

    def nodelist
      @has_body ? super : []
    end

    # Kept for the Tag#render interface and custom tags that call #render.
    def render(context)
      render_to_output_buffer(context, +'')
    end

    # Render is usually a single, body-less tag, but it can optionally take a
    # body of slot blocks closed by `endrender`. Since such a body may only
    # contain `slot` tags (and whitespace), we look at the token right after
    # the tag: a `slot` tag means block form, anything else means a regular
    # body-less render and leaves the remaining tokens untouched.
    def parse(tokens)
      if block_form?(tokens)
        @has_body = true
        @slots = {}
        super
        validate_slot_body!
      else
        @has_body = false
        @slots = nil
      end
    end

    def block_name
      'render'
    end

    def block_delimiter
      'endrender'
    end

    # The body of a block-form render may only contain `slot` blocks.
    def unknown_tag(tag_name, _markup, _tokenizer)
      raise SyntaxError, parse_context.locale.t("errors.syntax.render_only_slot_tags", tag: tag_name)
    end

    def render_to_output_buffer(context, output)
      render_tag(context, output)
    end

    def render_tag(context, output)
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

        attribute_values = {}
        @attributes.each do |key, value|
          attribute_values[key] = context.evaluate(value)
          inner_context[key] = attribute_values[key]
        end
        inner_context[context_variable_name] = var unless var.nil?

        build_slot_invocations!(inner_context, context, attribute_values, var, forloop, context_variable_name)

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
        ] + @node.attributes.values
      end
    end

    private

    # A render tag opens a body only when the first non-whitespace token
    # following it is a `slot` tag.
    def block_form?(tokens)
      ahead = 0
      while (token = tokens.peek(ahead))
        unless token.strip.empty?
          match = token.match(BlockBody::FullToken)
          return !match.nil? && match[2] == 'slot'
        end

        ahead += 1
      end
      false
    end

    def validate_slot_body!
      @body.nodelist.each do |node|
        next if node.is_a?(Liquid::Slot) || node.instance_of?(String) && node.strip.empty?

        tag = node.respond_to?(:tag_name) ? node.tag_name : node.inspect
        raise SyntaxError, parse_context.locale.t("errors.syntax.render_only_slot_tags", tag: tag)
      end

      @body.nodelist.each do |node|
        next unless node.is_a?(Liquid::Slot)

        name = node.slot_name
        if @slots.key?(name)
          raise SyntaxError, parse_context.locale.t("errors.syntax.render_duplicate_slot", name: name)
        end

        @slots[name] = node
      end
    end

    # Gives the snippet a name -> Slot::Invocation map. Each invocation
    # captures the caller's context and this iteration's parameter bindings;
    # the snippet can then evaluate a slot any number of times, each time in a
    # fresh frame with independent bindings.
    def build_slot_invocations!(inner_context, caller_context, attribute_values, var, forloop, context_variable_name)
      return unless @has_body

      slot_base_scope = attribute_values.dup
      slot_base_scope[context_variable_name] = var unless var.nil?
      slot_base_scope['forloop'] = forloop if forloop

      invocations = {}
      @slots.each do |name, slot_node|
        invocations[name] = Slot::Invocation.new(slot_node.slot_body, caller_context, slot_base_scope)
      end
      inner_context.set_render_slots(invocations)
    end
  end
end
