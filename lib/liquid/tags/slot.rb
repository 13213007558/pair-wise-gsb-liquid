# frozen_string_literal: true

module Liquid
  # @liquid_public_docs
  # @liquid_type tag
  # @liquid_category theme
  # @liquid_name slot
  # @liquid_summary
  #   Renders a named content slot inside a snippet, or supplies content for a
  #   slot when calling {Liquid::Render} with a body.
  # @liquid_description
  #   Inside a snippet, `{% slot %}` marks a place where the caller can inject
  #   content. The tag's body is rendered as default content when the caller
  #   did not supply the slot.
  #
  #   Inside the body of a `{% render %}` tag, `{% slot %}` supplies content for
  #   the named slot. Supplied content is only evaluated when the snippet uses
  #   the slot, and it is evaluated in the caller's scope: it can read the
  #   caller's variables and the arguments passed to `render` (including each
  #   iteration's variable when rendering `for` a collection), while variables
  #   created inside the snippet are not visible and never leak back to the
  #   caller.
  # @liquid_syntax
  #   {% slot 'name' %}default content{% endslot %}
  # @liquid_syntax
  #   {% render 'snippet' %}{% slot 'name' %}content{% endslot %}{% endrender %}
  class Slot < Block
    include ParserSwitching

    Syntax = /(#{QuotedFragment}+)/o

    # Special context key under which a render call exposes the slot contents
    # it received. Never collides with a Liquid variable name since the lookup
    # uses a symbol internally.
    RENDER_SLOTS_KEY = :__liquid_render_slots__

    attr_reader :slot_name

    def initialize(tag_name, markup, options)
      super
      parse_with_selected_parser(markup)
    end

    def blank?
      false
    end

    # The content captured between `{% slot %}` and `{% endslot %}`. Rendered
    # as default content in an outlet, or captured by a block-form {Render}
    # and passed to the snippet as supplied content.
    def slot_body
      @body
    end

    # Renders an outlet inside a snippet: either the content supplied by the
    # caller (evaluated lazily in the caller's scope) or the tag's own default
    # body (rendered inside the snippet).
    def render_tag(context, output)
      slots = context.find_variable(RENDER_SLOTS_KEY, raise_on_not_found: false)
      invocation = slots.is_a?(Hash) ? slots[@slot_name] : nil

      if invocation
        invocation.render_to_output_buffer(context, output)
      else
        # Render default content in an ephemeral assignment scope so values
        # assigned in one use of the slot don't leak into the next use.
        context.with_isolated_assigns do
          @body.render_to_output_buffer(context, output)
        end
      end

      output
    end

    def render_to_output_buffer(context, output)
      render_tag(context, output)
    end

    # render (string)
    def strict2_parse(markup)
      p = @parse_context.new_parser(markup)

      if p.look(:string)
        name_token = p.consume(:string)
        @slot_name = name_token[1...-1]
      else
        @slot_name = p.consume(:id)
      end

      p.consume(:end_of_string)
      raise SyntaxError, parse_context.locale.t('errors.syntax.slot') if @slot_name.empty?
    end

    def strict_parse(markup)
      lax_parse(markup)
    end

    def lax_parse(markup)
      raise SyntaxError, parse_context.locale.t('errors.syntax.slot') unless markup =~ Syntax

      name = Regexp.last_match(1)
      name = name[1...-1] if name.start_with?('"', "'")
      raise SyntaxError, parse_context.locale.t('errors.syntax.slot') if name.empty?

      @slot_name = name
    end

    # A chunk of content supplied to a {Render} call. It is evaluated only when
    # the rendered snippet asks for it, in an ephemeral scope on top of the
    # caller's context: caller variables are visible, render arguments and the
    # current `for` iteration are bound into the scope, and anything assigned
    # inside the slot is discarded afterwards. Every use of a slot (and every
    # iteration of a `render ... for` loop) gets its own scope, so parameter
    # bindings stay independent.
    class Invocation
      def initialize(slot_body, caller_context, base_scope)
        @body           = slot_body
        @caller_context = caller_context
        @base_scope     = base_scope
      end

      def render_to_output_buffer(_partial_context, output)
        @caller_context.with_isolated_assigns(@base_scope) do
          @body.render_to_output_buffer(@caller_context, output)
        end
        output
      end
    end
  end
end
