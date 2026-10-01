# frozen_string_literal: true

require 'set'
require_relative 'specializer/static_context'
require_relative 'specializer/nodes'

module Liquid
  # A Specializer partially evaluates a parsed Template against data that is
  # known to be identical across many renderings (for example a tenant name and
  # a fixed configuration hash). The result is a new Template that still
  # accepts the remaining, dynamic variables:
  #
  #   template    = Liquid::Template.parse(source)
  #   specialized = template.specialize(
  #     { 'tenant' => 'Acme', 'config' => config },
  #     pure_filters: [:upcase, MyPureFilters],
  #   )
  #   specialized.render('order' => order)
  #
  # Only ordinary plain data (nil, booleans, numbers, strings, symbols and
  # arrays/hashes thereof) is folded. Liquid::Drop values and Procs are never
  # touched, and only filters explicitly declared pure are ever invoked during
  # specialization. Conditions whose truthiness cannot be determined, loops
  # and variable shadowing are preserved with their original semantics.
  #
  # For any dynamic render input the specialized template produces the same
  # output, surfaces errors at the same source locations, and reaches the same
  # observable resource limits as the original template.
  class Specializer
    # Outcome of transforming a nodelist (or a single node).
    #
    # +nodes+::       nodes to render in place of the input
    # +render_cost+:: per-execution render score of the transformed subtree
    # +assign_cost+:: per-execution assign score while the output is captured
    # +folded+::      whether the whole subtree reduced to a fixed +output+
    SpecResult = Struct.new(:nodes, :render_cost, :assign_cost, :folded, :output, keyword_init: true)

    def self.plain?(value)
      case value
      when nil, true, false, Numeric, String, Symbol
        true
      when Array
        value.all? { |entry| plain?(entry) }
      when Hash
        value.all? { |key, entry| plain?(key) && plain?(entry) }
      else
        false
      end
    end

    def initialize(template, known_data, pure_filter_names:, extra_filter_modules:)
      @template = template
      @environment = template.instance_variable_get(:@environment) || Environment.default

      @known_data = deep_freeze_plain(known_data || {})
      @pure_filter_names = pure_filter_names
      @strainer = build_strainer(extra_filter_modules)

      unknown = pure_filter_names.reject { |name| @strainer.class.invokable?(name) }
      unless unknown.empty?
        raise Liquid::UndefinedFilter,
          "cannot specialize with pure filter#{'s' if unknown.length > 1} #{unknown.to_a.inspect} " \
          "that #{'are' if unknown.length > 1}#{'is' if unknown.length == 1} not registered"
      end

      @static = StaticContext.new
    end

    def specialize
      document = @template.root
      unless document
        raise Liquid::Error, "cannot specialize a template that has not been parsed"
      end

      # The root frame holds the known data (frozen); a mutable frame above it
      # collects specialization-time bindings so the caller's hashes are never
      # mutated.
      @static.push_frame(@known_data, [])
      @static.push_frame({}, [])
      begin
        result = specialize_nodelist(@template.root.body.nodelist, speculative: false)
      ensure
        @static.pop_frame
        @static.pop_frame
      end

      build_template(result.nodes)
    end

    private

    # --- setup ---------------------------------------------------------------

    def build_strainer(extra_filter_modules)
      modules = Array(extra_filter_modules)
      invalid = modules.reject { |mod| mod.is_a?(Module) }
      unless invalid.empty?
        raise ArgumentError, "filters entries must be Modules: #{invalid.inspect}"
      end

      # The context argument is only consulted by collection filters while
      # walking nested values; plain data never reaches those paths.
      @environment.create_strainer(nil, modules)
    end

    # Validates and copies the caller's known data. Strings are frozen;
    # collections are deep-copied but left unfrozen so that (a) the caller's
    # objects can never be mutated during specialization or rendering, and
    # (b) residual collection literals remain mutable the way ordinary Liquid
    # values are.
    def deep_freeze_plain(value)
      case value
      when Integer, Float, Symbol, nil, true, false
        value
      when Numeric
        value
      when String
        value.dup.freeze
      when Array
        value.map { |entry| deep_freeze_plain(entry) }
      when Hash
        value.each_with_object({}) do |(key, entry), acc|
          acc[deep_freeze_plain(key)] = deep_freeze_plain(entry)
        end
      else
        raise ArgumentError,
          "specialize only accepts plain data (nil, booleans, numbers, strings, " \
          "symbols, arrays and hashes); got #{value.class}"
      end
    end

    # --- scope handling ------------------------------------------------------

    def bind_static(name, value)
      static_bindings, = @static.frames.last
      static_bindings[name] = value
    end

    def bind_dynamic(name)
      _, dynamic_names = @static.frames.last
      dynamic_names << name unless dynamic_names.include?(name)
    end

    def with_frame(static_bindings = {}, dynamic_names = [])
      @static.push_frame(static_bindings, dynamic_names)
      yield
    ensure
      @static.pop_frame
    end

    # --- static expression helpers ------------------------------------------

    def static_evaluate(expr)
      @static.evaluate(expr)
    end

    def static_evaluate_condition(condition)
      @static.evaluate_condition(condition)
    end

    # Reduces an expression to literals when possible, keeping it otherwise.
    def literalize_or_keep(expr)
      @static.evaluate(expr)
    rescue StaticContext::DynamicExpression
      expr
    end

    def plain_static?(expr)
      value = @static.evaluate(expr)
      self.class.plain?(value) ? value : nil
    rescue StaticContext::DynamicExpression
      nil
    end

    # --- filter folding ------------------------------------------------------

    # Walks a Variable's value and filter chain, precomputing a leading run of
    # explicitly-pure filters whose arguments are statically plain.
    #
    # Returns a residual Variable when the root value is statically known
    # (fully folded, partially folded, or unchanged because all filters had to
    # be kept), or nil when the root value itself is dynamic.
    def residual_variable(variable, fold_filters: true)
      value = @static.evaluate(variable.name)
      return nil unless self.class.plain?(value)

      variable.filters.each_with_index do |(filter_name, filter_args, filter_kwargs), index|
        static_args, static_kwargs = static_filter_arguments(filter_args, filter_kwargs)

        if fold_filters &&
            @pure_filter_names.include?(filter_name) &&
            @strainer.class.invokable?(filter_name) && static_args &&
            (filter_kwargs.nil? || static_kwargs)
          call_args = static_args
          call_args = call_args + [static_kwargs] if filter_kwargs
          folded = invoke_pure_filter_or_error(filter_name, value, call_args)

          if folded.equal?(FILTER_ERROR_MARKER)
            # Pure filter raised on statically known arguments: keep this
            # filter (with literalized args) and every following filter, so
            # the error is produced at render in the same position.
            return make_residual_variable(variable, value,
              literal_filter_list(variable.filters[index..]))
          elsif self.class.plain?(folded)
            value = folded
            next
          end
        end

        # Non-pure/unknown filter, non-plain argument or non-plain result:
        # keep this filter and everything after it.
        return make_residual_variable(variable, value,
          literal_filter_list(variable.filters[index..]))
      end

      make_residual_variable(variable, value, [])
    rescue StaticContext::DynamicExpression
      nil
    end

    def invoke_pure_filter_or_error(filter_name, value, args)
      result = @strainer.invoke(filter_name, value, *args)
      result.respond_to?(:to_liquid) ? result.to_liquid : result
    rescue ::StandardError
      filter_error_marker
    end

    # A distinct frozen object returned when a declared-pure filter fails on
    # statically known arguments (the failure is then reproduced at render).
    FILTER_ERROR_MARKER = Object.new.freeze

    def filter_error_marker
      FILTER_ERROR_MARKER
    end

    # Converts parsed filter tuples into tuples where every foldable argument
    # is replaced by its literal value. Filter tuples may be 2 or 3 elements.
    def literal_filter_list(filters)
      filters.map do |name, args, kwargs|
        tuple = [name, args.map { |expr| literalize_or_keep(expr) }]
        tuple << kwargs.transform_values { |expr| literalize_or_keep(expr) } if kwargs
        tuple
      end
    end

    def static_filter_arguments(args, kwargs)
      static_args = []
      args.each do |expr|
        value = @static.evaluate(expr)
        return [nil, nil] unless self.class.plain?(value)
        static_args << value
      end

      static_kwargs = nil
      if kwargs
        static_kwargs = {}
        kwargs.each do |key, expr|
          value = @static.evaluate(expr)
          return [nil, nil] unless self.class.plain?(value)
          static_kwargs[key] = value
        end
      end

      [static_args, static_kwargs]
    rescue StaticContext::DynamicExpression
      [nil, nil]
    end

    def make_residual_variable(original, value, remaining_filters)
      residual = Variable.allocate
      residual.instance_variable_set(:@name, value)
      residual.instance_variable_set(:@filters, remaining_filters)
      residual.instance_variable_set(:@parse_context, original.parse_context)
      residual.instance_variable_set(:@line_number, original.line_number)
      residual.instance_variable_set(:@markup, original.raw)
      residual
    end

    # --- node list transformation -------------------------------------------

    def specialize_nodelist(nodelist, speculative:)
      nodes = []
      render_cost = 0
      assign_cost = 0
      fully_folded = true

      nodelist.each do |node|
        if node.instance_of?(String)
          nodes << node
          render_cost += 1
          next
        end

        specialized = specialize_node(node, speculative)

        render_cost += specialized.render_cost
        assign_cost += specialized.assign_cost
        fully_folded = false unless specialized.folded
        nodes.concat(specialized.nodes)
      end

      SpecResult.new(nodes: nodes, render_cost: render_cost,
        assign_cost: assign_cost, folded: fully_folded,
        output: fully_folded ? render_fixed_nodelist(nodes) : nil)
    end

    # Renders a fully folded nodelist into its fixed string. Fully folded
    # nodelists contain strings plus no-output nodes (StaticCharge 0,
    # StaticAssign/StaticCaptureAssign); adjacent strings are returned merged
    # so the enclosing construct can emit the whole fixed region as one node.
    def render_fixed_nodelist(nodes)
      output = +''
      nodes.each do |node|
        output << node if node.instance_of?(String)
      end
      output
    end

    def specialize_node(node, speculative)
      case node
      when Variable
        specialize_output_variable(node, speculative)
      when Echo
        specialize_echo(node, speculative)
      when If
        specialize_if(node, speculative)
      when Case
        specialize_case(node, speculative)
      when For
        specialize_for(node, speculative)
      when TableRow
        specialize_tablerow(node, speculative)
      when Assign
        specialize_assign(node, speculative)
      when Capture
        specialize_capture(node, speculative)
      when Block
        # Control-flow blocks are handled above; opaque block tags (raw,
        # comment, ifchanged, custom tags) are preserved with their bodies
        # specialized, except tags whose bodies carry non-output semantics.
        specialize_generic_block(node, speculative)
      else
        # render, include, increment, decrement, cycle, break, continue and
        # custom non-block tags are preserved verbatim.
        dynamic_result([node], 1, 0)
      end
    end

    def dynamic_result(nodes, render_cost, assign_cost)
      SpecResult.new(nodes: nodes, render_cost: render_cost,
        assign_cost: assign_cost, folded: false, output: nil)
    end

    # --- {{ output }} --------------------------------------------------------

    def specialize_output_variable(node, speculative)
      # In speculative regions (loop bodies, undecidable conditionals) known
      # variables are still literalized, but no filter is folded because its
      # evaluation count is data dependent.
      residual = residual_variable(node, fold_filters: !speculative)
      dynamic_result([residual || node], 1, 0)
    end

    # --- if / unless --------------------------------------------------------

    def specialize_if(node, speculative)
      # Unless inverts the truthiness of its first block only; elsif/else
      # blocks behave like If.
      invert_first = node.is_a?(Unless)

      decision, selected_index = decide_if(node.blocks, invert_first)

      case decision
      when :false
        # The tag occupied one slot even though no body rendered.
        dynamic_result([StaticCharge.new(1)], 1, 0)
      when :true
        specialize_taken_branch(node, selected_index, speculative)
      else
        preserve_if(node)
      end
    end

    # Returns [:false, nil], [:true, index] or [:dynamic, nil].
    def decide_if(blocks, invert_first = false)
      blocks.each_with_index do |block, index|
        return [:true, index] if block.else?

        result = static_evaluate_condition(block)
        result = !Liquid::Utils.to_liquid_value(result) if invert_first && index == 0
        return [:true, index] if Liquid::Utils.to_liquid_value(result)
      end
      [:false, nil]
    rescue StaticContext::DynamicExpression
      [:dynamic, nil]
    rescue ::StandardError
      # A reachable static comparison error (e.g. comparing String with
      # Integer) must be reproduced at render time at the same source location,
      # so the tag and its condition are preserved.
      [:dynamic, nil]
    end

    # Cost parity for a collapsed selected branch.
    #
    # The parent BlockBody charges one for every node it contains. The
    # original tag occupied one slot and the rendered attachment charged its
    # own nodelist length. After collapsing, the emitted nodes occupy the
    # parent slots and a single StaticCharge adjusts for the attachment's
    # length charge so the total is identical.
    def specialize_taken_branch(node, index, speculative)
      body_result = specialize_nodelist(node.blocks[index].attachment.nodelist, speculative: speculative)

      # Original cost = 1 (the tag slot, charged before the body) +
      # attachment nodelist length. The inlined body nodes reproduce the body
      # charges; the tag's slot charge is emitted FIRST so a render-score
      # threshold is reached at exactly the same point as in the original.
      # Charge the tag slot first (matching the original BlockBody charge),
      # then each inlined body node charges its own slot as it executes.
      nodes = [StaticCharge.new(1)]
      nodes.concat(body_result.nodes.map { |n| inline_node(n) })
      dynamic_result(nodes, 1 + body_result.render_cost, body_result.assign_cost)
    end

    def preserve_if(node)
      new_blocks = node.blocks.map { |block| rebuild_condition_block(block) }

      # Each branch runs in an isolated frame (Liquid if-branches share the
      # outer scope, but the static analysis must not let one branch's
      # bindings leak into another's evaluation). Afterwards, names bound in
      # any reachable branch are merged back: static values only when every
      # branch agrees, otherwise dynamic.
      branch_frames = []
      node.blocks.each_with_index do |block, index|
        with_frame do
          body_result = specialize_nodelist(block.attachment.nodelist, speculative: true)
          attach_body(new_blocks[index], body_result)
          branch_frames << current_frame
        end
      end

      merge_branch_bindings(branch_frames)

      copy = node.dup
      copy.instance_variable_set(:@blocks, new_blocks)
      dynamic_result([copy], 1, 0)
    end

    def current_frame
      @static.frames.last
    end

    # Merges bindings produced by mutually exclusive (but all reachable)
    # branches into the enclosing frame.
    def merge_branch_bindings(branch_frames)
      parent_static, parent_dynamic = @static.frames.last

      all_dynamic = branch_frames.flat_map { |_, dynamic| dynamic }.uniq
      all_dynamic.each do |name|
        unless parent_dynamic.include?(name)
          parent_dynamic << name
          parent_static.delete(name)
        end
      end

      values_by_name = {}
      branch_frames.each do |static, _dynamic|
        static.each_key do |name|
          next if parent_dynamic.include?(name)
          (values_by_name[name] ||= []) << static[name]
        end
      end

      values_by_name.each do |name, values|
        next if values.length != branch_frames.length
        first = values.first
        parent_static[name] = first if values.all? { |value| value.equal?(first) || value == first }
      end
    end

    def rebuild_condition_block(block)
      if block.else?
        ElseCondition.allocate
      else
        rebuild_condition_chain(block)
      end
    end

    # Duplicates an and/or Condition chain, literalizing static operands while
    # keeping the chain structure and reachable error positions intact.
    def rebuild_condition_chain(condition)
      new_condition = Condition.allocate
      new_condition.instance_variable_set(:@left, literalize_or_keep(condition.left))
      new_condition.instance_variable_set(:@right, condition.right.nil? ? nil : literalize_or_keep(condition.right))
      new_condition.instance_variable_set(:@operator, condition.operator)
      new_condition.instance_variable_set(:@child_relation, nil)
      new_condition.instance_variable_set(:@child_condition, nil)

      if condition.instance_variable_get(:@child_condition)
        child = rebuild_condition_chain(condition.instance_variable_get(:@child_condition))
        case condition.instance_variable_get(:@child_relation)
        when :or
          new_condition.or(child)
        when :and
          new_condition.and(child)
        end
      end

      new_condition
    end

    # --- case ---------------------------------------------------------------

    def specialize_case(node, speculative)
      return preserve_case(node) if plain_static?(node.left).nil?

      # Emulate Case#render_to_output_buffer exactly: every condition is
      # evaluated once (conditions themselves add no render score); a matched
      # body's BlockBody charges its nodelist length; the else body charges iff
      # nothing matched. Consecutive when blocks can share a body, so each
      # distinct attachment is specialized at most once.
      body_nodes = []
      render_cost = 0
      assign_cost = 0
      execute_else = true
      specialized_bodies = {}
      rendered_bodies = {}

      node.blocks.each do |block|
        if block.else?
          next unless execute_else
        else
          result = begin
            static_evaluate_condition(block)
          rescue StaticContext::DynamicExpression, ::StandardError
            return preserve_case(node)
          end

          next unless Liquid::Utils.to_liquid_value(result)

          execute_else = false
        end

        body = specialized_bodies[block.attachment] ||=
          specialize_nodelist(block.attachment.nodelist, speculative: speculative)
        next if rendered_bodies[block.attachment]

        rendered_bodies[block.attachment] = true
        render_cost += body.render_cost
        assign_cost += body.assign_cost
        body_nodes.concat(body.nodes)
      end

      # The case tag occupied one slot (charged before body rendering) plus
      # matched body length charges; reproduce the slot charge first.
      nodes = [StaticCharge.new(1)]
      nodes.concat(body_nodes.map { |n| inline_node(n) })
      dynamic_result(nodes, 1 + render_cost, assign_cost)
    end

    def preserve_case(node)
      new_blocks = node.blocks.map do |block|
        if block.else?
          ElseCondition.allocate
        else
          copy = Condition.allocate
          copy.instance_variable_set(:@left, literalize_or_keep(block.left))
          copy.instance_variable_set(:@right, literalize_or_keep(block.right))
          copy.instance_variable_set(:@operator, '==')
          copy.instance_variable_set(:@child_relation, nil)
          copy.instance_variable_set(:@child_condition, nil)
          copy
        end
      end

      branch_frames = []
      node.blocks.each_with_index do |block, index|
        with_frame do
          body_result = specialize_nodelist(block.attachment.nodelist, speculative: true)
          attach_body(new_blocks[index], body_result)
          branch_frames << current_frame
        end
      end

      merge_branch_bindings(branch_frames)

      copy = node.dup
      copy.instance_variable_set(:@blocks, new_blocks)
      dynamic_result([copy], 1, 0)
    end

    # --- for ----------------------------------------------------------------

    def specialize_for(node, _speculative)
      copy = node.dup
      copy.instance_variable_set(:@collection_name, literalize_or_keep(node.collection_name))
      copy.instance_variable_set(:@from,
        node.from.nil? || node.from == :continue ? node.from : literalize_or_keep(node.from))
      copy.instance_variable_set(:@limit, node.limit.nil? ? nil : literalize_or_keep(node.limit))

      with_frame({}, [node.variable_name]) do
        for_result = specialize_nodelist(node.instance_variable_get(:@for_block).nodelist, speculative: true)
        copy.instance_variable_set(:@for_block, build_body(for_result))
        if node.instance_variable_get(:@else_block)
          else_result = specialize_nodelist(node.instance_variable_get(:@else_block).nodelist, speculative: true)
          copy.instance_variable_set(:@else_block, build_body(else_result))
        end
      end

      # The For tag iterates at render time and charges per element, so loops
      # are never unrolled.
      dynamic_result([copy], 1, 0)
    end

    # --- tablerow ------------------------------------------------------------

    def specialize_tablerow(node, _speculative)
      copy = node.dup
      copy.instance_variable_set(:@collection_name, literalize_or_keep(node.collection_name))
      attributes = node.attributes.transform_values { |expr| literalize_or_keep(expr) }
      copy.instance_variable_set(:@attributes, attributes)

      with_frame({}, [node.variable_name]) do
        body_result = specialize_nodelist(node.nodelist, speculative: true)
        copy.instance_variable_set(:@body, build_body(body_result))
      end

      dynamic_result([copy], 1, 0)
    end

    # --- echo ---------------------------------------------------------------

    def specialize_echo(node, speculative)
      residual = residual_variable(node.variable, fold_filters: !speculative)
      if residual
        copy = node.dup
        copy.instance_variable_set(:@variable, residual)
        return dynamic_result([copy], 1, 0)
      end
      dynamic_result([node], 1, 0)
    end

    # --- generic block tags --------------------------------------------------

    # Opaque block tags whose body must not be folded (they never render their
    # body as ordinary output, or folding would change their semantics).
    OPAQUE_BLOCK_TAGS = ['raw', 'comment', 'doc'].freeze

    def specialize_generic_block(node, speculative)
      if OPAQUE_BLOCK_TAGS.include?(node.tag_name)
        return dynamic_result([node], 1, 0)
      end

      copy = node.dup
      body_result = specialize_nodelist(node.nodelist, speculative: speculative)
      copy.instance_variable_set(:@body, build_body(body_result))
      dynamic_result([copy], 1 + body_result.render_cost, body_result.assign_cost)
    end

    def inline_node(node)
      return node if node.respond_to?(:skip_slot_charge?) && node.skip_slot_charge?
      InlineNode.new(node)
    end

    def build_body(body_result)
      body = BlockBody.allocate
      body.instance_variable_set(:@nodelist, body_result.nodes)
      body.instance_variable_set(:@blank, true)
      body.instance_variable_set(:@explicit_slot_charges, true)
      body
    end

    def attach_body(condition, body_result)
      condition.instance_variable_set(:@attachment, build_body(body_result))
    end

    # --- assign -------------------------------------------------------------

    def specialize_assign(node, speculative)
      residual = residual_variable(node.from, fold_filters: !speculative)

      if !speculative && residual && residual.filters.empty?
        value = residual.name
        bind_static(node.to, value)
        score = assign_score_of(value)
        return dynamic_result([StaticAssign.new(node.to, value, score)], 1, score)
      end

      if residual
        # Static root but filters had to stay (or we are inside a speculative
        # region): the result is data dependent, keep an {% assign %} with the
        # residual expression.
        bind_dynamic(node.to)
        copy = node.dup
        copy.instance_variable_set(:@from, residual)
        return dynamic_result([copy], 1, 0)
      end

      bind_dynamic(node.to)
      dynamic_result([node], 1, 0)
    end

    # --- capture ------------------------------------------------------------

    def specialize_capture(node, speculative)
      body_result = specialize_nodelist(node.nodelist, speculative: speculative)

      if !speculative && body_result.folded
        captured = body_result.output.dup
        bind_static(node.to, captured)
        assign_score = captured.bytesize + body_result.assign_cost
        # The capture occupied one slot and its body accrued captured render
        # score; the replacement node occupies that single slot and accrues
        # the same score (bypassing the render-length limit, as capture does).
        return dynamic_result(
          [StaticCaptureAssign.new(node.to, captured, assign_score, body_result.render_cost - 1)],
          body_result.render_cost, assign_score)
      end

      bind_dynamic(node.to)
      copy = node.dup
      copy.instance_variable_set(:@body, build_body(body_result))
      dynamic_result([copy], 1 + body_result.render_cost, 0)
    end

    # --- helpers -------------------------------------------------------------

    def assign_score_of(value)
      case value
      when String
        value.instance_of?(String) ? value.bytesize : 1
      when Array
        sum = 1
        value.each { |child| sum += assign_score_of(child) }
        sum
      when Hash
        sum = 1
        value.each do |key, entry_value|
          sum += assign_score_of(key)
          sum += assign_score_of(entry_value)
        end
        sum
      else
        1
      end
    end

    def build_template(nodes)
      body = BlockBody.allocate
      body.instance_variable_set(:@nodelist, nodes)
      body.instance_variable_set(:@blank, false)
      body.instance_variable_set(:@explicit_slot_charges, true)
      body.freeze

      document = Document.allocate
      document.instance_variable_set(:@parse_context, @template.root.parse_context)
      document.instance_variable_set(:@body, body)
      document.freeze

      specialized = Template.allocate
      specialized.instance_variable_set(:@environment, @environment)
      specialized.instance_variable_set(:@rethrow_errors, false)
      specialized.instance_variable_set(:@resource_limits,
        ResourceLimits.new(@environment.default_resource_limits))
      specialized.instance_variable_set(:@root, document)
      specialized.instance_variable_set(:@name, @template.name)

      # Residual nodes can still reference variables that were statically
      # known (e.g. a known collection indexed by a dynamic key). Template
      # assigns are merged into every render behind the caller's data, so
      # dynamic variables shadow them exactly like Liquid scopes.
      specialized.instance_variable_set(:@assigns, deep_dup_plain(@known_data))

      specialized
    end

    def deep_dup_plain(value)
      case value
      when Integer, Float, Symbol, nil, true, false, Numeric
        value
      when String
        value.dup
      when Array
        value.map { |entry| deep_dup_plain(entry) }
      when Hash
        value.each_with_object({}) do |(key, entry), acc|
          acc[deep_dup_plain(key)] = deep_dup_plain(entry)
        end
      else
        value
      end
    end
  end
end
