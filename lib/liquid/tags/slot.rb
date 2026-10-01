# frozen_string_literal: true

module Liquid
  # @liquid_public_docs
  # @liquid_type tag
  # @liquid_category theme
  # @liquid_name slot
  # @liquid_summary
  #   Defines or renders a named content [slot](/docs/api/liquid/tags/render#slots).
  # @liquid_description
  #   A slot has two uses:
  #
  #   - Inside a `{% render %}` block, a `slot` block supplies content that the
  #     rendered snippet can render by name.
  #   - Inside a snippet, a `slot` block renders the content supplied by the
  #     caller for that name. If the caller didn't supply the slot, the block
  #     body is rendered as default content instead. An empty body means the
  #     slot renders nothing when not supplied.
  #
  #   Slot content is evaluated lazily, only when (and each time) the snippet
  #   renders it, and it is evaluated in the caller's variable environment.
  #   Variables assigned inside a slot don't leak out, and per-render
  #   parameters (such as the current item of a `render ... for` loop) are bound
  #   independently for each invocation.
  # @liquid_syntax
  #   {% slot name %}
  #     default content
  #   {% endslot %}
  # @liquid_syntax_keyword name The name of the slot.
  class Slot < Block
    SYNTAX = /\A(#{VariableSegment}+)\z/o

    attr_reader :slot_name, :slot_body

    def initialize(tag_name, markup, options)
      super
      @slot_name = markup.to_s.strip
      raise SyntaxError, options[:locale].t("errors.syntax.slot") unless @slot_name =~ SYNTAX
      @slot_body = new_body
    end

    def parse(tokens)
      @for_liquid_tag = tokens.for_liquid_tag
      while parse_body(@slot_body, tokens)
      end
      @slot_body.remove_blank_strings if blank?
      @slot_body.freeze
    end

    def nodelist
      [@slot_body]
    end

    def block_name
      'slot'
    end

    def block_delimiter
      'endslot'
    end

    def render_to_output_buffer(context, output)
      invocation = context.slots&.[](@slot_name)
      if invocation
        invocation.render_to_output_buffer(output, context)
      else
        @slot_body.render_to_output_buffer(context, output)
      end
    end

    class ParseTreeVisitor < Liquid::ParseTreeVisitor
      def children
        [@node.slot_body]
      end
    end

    # Inside a {% liquid %} tag each body line is its own token, and a bare word
    # line that doesn't name a registered tag is plain slot content. In a normal
    # template a non-tag yielded here is an actual unknown tag and stays an error.
    def unknown_tag(tag, markup, _tokens)
      if @for_liquid_tag && (markup.nil? || markup.empty?)
        @slot_body.nodelist << tag
        @blank = false
      else
        super
      end
    end
  end

  # @api private
  #
  # The stack of slot frames introduced by nested render calls. Each frame maps
  # slot names to {SlotInvocation}s. A slot resolves to the invocation in the
  # nearest frame that defines it, so a nested snippet can transparently
  # forward caller supplied content while overriding individual slots with its
  # own supplied blocks.
  class SlotStack
    def initialize(frames = nil)
      @frames = frames || []
    end

    def [](name)
      # The nearest render frame wins: a snippet's own supplied slot blocks
      # take precedence over content forwarded from an enclosing render.
      @frames.reverse_each do |frame|
        return frame[name] if frame.key?(name)
      end
      nil
    end

    # Builds the stack visible inside a nested isolated snippet context.
    # Enclosing frames are forwarded read-only with every invocation re-bound
    # to the nested render's per-invocation parameters (e.g. the current `for`
    # item). A new frame holding the blocks supplied directly to this render
    # is pushed on top; only the names it defines shadow the frames below, so
    # unrelated caller slots keep passing through.
    def for_render(own_frame, bindings)
      frames = @frames.map do |frame|
        frame.transform_values { |invocation| invocation.rebind(bindings) }
      end
      frames << own_frame
      SlotStack.new(frames)
    end
  end

  # @api private
  #
  # Binds a caller supplied slot body to the environment in which the slot was
  # passed. A new invocation is created for every rendering of a snippet, so
  # parameters such as the current `render ... for` item are bound independently
  # per invocation even when the same slot is rendered multiple times.
  #
  # The body is rendered lazily (only when the snippet actually renders the
  # slot) inside an isolated context populated with the caller's local variables
  # and the per-invocation render bindings. Consequently the slot can read the
  # caller's environment, but `assign`s made while rendering the slot can never
  # leak back into the caller or into other slot invocations.
  class SlotInvocation
    def initialize(body, caller_context, bindings = nil)
      @body = body
      @caller_context = caller_context
      @bindings = bindings || Const::EMPTY_HASH
    end

    # Re-binds this slot body to another invocation's parameters. The slot body
    # keeps evaluating lazily in its original caller environment, but it
    # additionally sees the render parameters of the invocation from which it is
    # rendered (e.g. the current item when a nested snippet is rendered `for` a
    # collection). Existing bindings take precedence so intermediate snippets
    # can shadow outer parameters.
    def rebind(bindings)
      self.class.new(@body, @caller_context, bindings.merge(@bindings))
    end

    # +rendering_context+ is the isolated snippet context in which the `slot`
    # tag appears; it provides the template name and disabled-tag state that
    # rendering the slot content is attributed to.
    def render_to_output_buffer(output, rendering_context)
      slot_context = build_context(@caller_context)
      slot_context.template_name = rendering_context.template_name
      slot_context.disabled_tags.merge!(rendering_context.disabled_tags)
      @body.render_to_output_buffer(slot_context, output)
    end

    private

    def build_context(caller_context)
      slot_context = caller_context.new_isolated_subcontext
      slot_context.partial = true

      # Expose the caller's local environment as a single snapshot (inner
      # scopes win over outer ones), with the render bindings for this
      # invocation taking top priority. Global objects and registers are shared
      # through the isolated subcontext, while the slot gets a fresh stack so
      # that `assign`s made while rendering it cannot leak back to the caller.
      caller_locals = caller_context.scopes.reverse_each.reduce({}) do |snapshot, scope|
        snapshot.merge!(scope)
      end
      slot_context.merge(caller_locals.merge(@bindings))
      slot_context
    end
  end
end
