# frozen_string_literal: true

module Liquid
  # Partially evaluates a parsed Liquid template against variables whose values
  # are already known before the template is rendered (for example a brand
  # configuration baked in at deploy time).
  #
  # The result is another {Liquid::Template} that produces exactly the same
  # output as the original for every possible assignment of the remaining
  # variables, and surfaces the same errors. Only work that is provably
  # independent of the remaining variables is collapsed:
  #
  # * constants and expressions composed entirely of known variables;
  # * branches whose condition is fully determined by known variables;
  # * finite loops over a fully known, bounded collection whose body depends
  #    neither on the loop machinery nor on any opaque tag;
  # * +assign+/+capture+ with a fully known right-hand side.
  #
  # Filters are executed only when explicitly registered as pure on the
  # environment. Drop methods, dynamic +include+/+render+ and custom tags are
  # never run at preprocessing time; branches depending on them are retained.
  #
  # @api private
  class Partial
    UNKNOWN = StaticEvaluator::UNKNOWN

    # Maximum number of iterations unrolled for a single loop. Matches the
    # render-time iteration cap.
    DEFAULT_MAX_UNROLLED_ITERATIONS = 50

    def self.evaluate(template, known_variables, options = {})
      new(template, known_variables, options).call
    end

    def initialize(template, known_variables, options)
      @template = template
      @environment = options[:environment] || Liquid::Environment.default
      @parse_context = ParseContext.new(options.merge(environment: @environment))
      pure_filters = options[:pure_filters]
      pure_filters = PureFilterRegistry.new(names: pure_filters) if pure_filters.is_a?(Array)
      @evaluator = StaticEvaluator.new(
        environment: @environment,
        pure_filters: pure_filters,
        strict_variables: options[:strict_variables] == true,
      )
      @max_unrolled = options.fetch(:max_unrolled_iterations, DEFAULT_MAX_UNROLLED_ITERATIONS)
      @known_variables = known_variables || {}
      @retained = []
    end

    def call
      scope = initial_scope
      nodes = transform_block_body(@template.root.body, scope)
      blank = transformed_blank?(@template.root.body, nodes)
      residual = build_residual(nodes, blank)
      residual.specialization_info = SpecializationInfo.new(@retained)
      residual
    end

    private

    # ---- scope ---------------------------------------------------------

    def initial_scope
      @known_variables.each_with_object({}) do |(key, value), scope|
        scope[key.to_s] = StaticEvaluator.prepare_value(value)
      end
    end

    def snapshot(scope)
      scope.dup
    end

    def restore(scope, snap)
      scope.replace(snap)
    end

    def invalidate_all!(scope)
      scope.each_key { |key| scope[key] = UNKNOWN }
    end

    # Merges scopes observed after executing alternative branches. A binding
    # is kept only when every branch assigns exactly the same (known) value;
    # otherwise it becomes UNKNOWN.
    def merge_scopes(base, *branch_scopes)
      merged = {}
      keys = branch_scopes.flat_map(&:keys).uniq
      keys.each do |key|
        values = branch_scopes.map { |scope| scope.fetch(key, UNKNOWN) }
        first = values.first
        merged[key] = values.all? { |value| value.equal?(first) } ? first : UNKNOWN
      end
      merged
    end

    def unknown?(value)
      value.equal?(UNKNOWN)
    end

    # ---- body ----------------------------------------------------------

    def transform_block_body(body, scope)
      body.nodelist.flat_map { |node| transform_node(node, scope) }
    end

    def transform_node(node, scope)
      case node
      when ::String
        [node]
      when Variable
        transform_output(node, scope)
      when Echo
        transform_echo(node, scope)
      when Assign
        transform_assign(node, scope)
      when Capture
        transform_capture(node, scope)
      when If, Unless
        transform_conditional(node, scope)
      when Case
        transform_case(node, scope)
      when For
        transform_for(node, scope)
      when Include, Render
        # Dynamic include/render must not run at preprocessing time. Include
        # can mutate outer variables, so invalidate every binding afterwards.
        invalidate_all!(scope)
        [node]
      when Increment, Decrement
        scope[node.variable_name] = UNKNOWN
        [node]
      when Cycle
        [node]
      when Break, Continue
        # Only reachable inside a retained loop body.
        [node]
      when Block, Tag
        # Custom tags must never execute at preprocessing time.
        invalidate_all!(scope)
        [node]
      else
        [node]
      end
    rescue ::StandardError
      raise if $!.is_a?(Liquid::UndefinedVariable)

      invalidate_all!(scope)
      [node]
    end

    def transformed_blank?(original_body, transformed_nodes)
      original_body.blank? && transformed_nodes.all? do |node|
        node.instance_of?(::String) && node.match?(BlockBody::WhitespaceOrNothing)
      end
    end

    # ---- output variables ----------------------------------------------

    def transform_output(variable_node, scope)
      value, folded = fold_prefix(variable_node, scope)
      if folded == variable_node.filters.length && !unknown?(value)
        [StaticOutput.new(value)]
      elsif folded.zero? && unknown?(value)
        record(variable_node.raw, "output")
        [variable_node]
      elsif folded.zero?
        # The leading name was static but none of the filters is pure: keep
        # the whole node so runtime filter semantics are preserved.
        record(variable_node.raw, "output")
        [variable_node]
      else
        nodes_for_partial_chain(variable_node, value, folded, variable_node.raw, "output")
      end
    end

    def transform_echo(echo_node, scope)
      variable_node = echo_node.variable
      value, folded = fold_prefix(variable_node, scope)
      if folded == variable_node.filters.length && !unknown?(value)
        [StaticOutput.new(value)]
      elsif folded.zero? && unknown?(value)
        record(echo_node.raw, "echo")
        [echo_node]
      elsif folded.zero?
        record(echo_node.raw, "echo")
        [echo_node]
      else
        nodes_for_partial_chain(variable_node, value, folded, echo_node.raw, "echo", echo_node)
      end
    end

    # Folds as many filters from the start of the chain as possible. Returns
    # [current_value, number_of_filters_applied].
    def fold_prefix(variable_node, scope)
      value = @evaluator.evaluate(variable_node.name, scope)
      applied = 0

      variable_node.filters.each do |filter_name, args, kwargs|
        break if unknown?(value)

        static_args = args.map { |arg| @evaluator.evaluate(arg, scope) }
        static_kwargs = kwargs && kwargs.transform_values { |arg| @evaluator.evaluate(arg, scope) }
        next_value = @evaluator.apply_filter(filter_name, value, static_args, static_kwargs)
        break if unknown?(next_value)

        value = next_value
        applied += 1
      end

      [value, applied]
    end

    def nodes_for_partial_chain(variable_node, value, folded, source, kind, echo_node = nil)
      remaining = variable_node.filters[folded..]
      if unknown?(value)
        markup = PartialSerializer.expression(variable_node.name)
        markup = append_filters(markup, remaining)
        record(markup, kind)
        new_variable_node = new_variable(markup, variable_node.line_number)
        echo_node ? new_echo(new_variable_node) : [new_variable_node]
      elsif scalar_literal?(value)
        markup = PartialSerializer.expression(value)
        markup = append_filters(markup, remaining)
        [new_variable(markup, variable_node.line_number)]
      else
        # Non-scalar known value (array/hash) cannot be inlined as a literal
        # feeding a remaining filter; keep the original expression. Sound, just
        # less profitable.
        record(source, kind)
        echo_node ? [echo_node] : [variable_node]
      end
    end

    def append_filters(markup, filters)
      filters.each do |filter_name, args, kwargs|
        markup = "#{markup} | #{filter_name}"
        arg_list = PartialSerializer.serialized_filter_args(args, kwargs)
        markup = "#{markup}: #{arg_list}" if arg_list
      end
      markup
    end

    def scalar_literal?(value)
      value.nil? || value.is_a?(::String) || value.is_a?(Numeric) || value == true || value == false
    end

    def new_variable(markup, line_number = nil)
      node = Variable.new(markup, @parse_context)
      node.line_number = line_number if line_number
      node
    end

    def new_echo(variable_node)
      [new_variable(PartialSerializer.variable(variable_node), variable_node.line_number)]
    end

    # ---- assign --------------------------------------------------------

    def transform_assign(node, scope)
      value, folded = fold_prefix(node.from, scope)
      if folded == node.from.filters.length && !unknown?(value)
        scope[node.to] = value
        []
      elsif folded.zero? && unknown?(@evaluator.evaluate(node.from.name, scope))
        scope[node.to] = UNKNOWN
        record(node.raw, "assign")
        [node]
      else
        scope[node.to] = UNKNOWN
        build_partial_assign(node, value, folded)
      end
    end

    def build_partial_assign(node, value, folded)
      if unknown?(value) || !scalar_literal?(value)
        record(node.raw, "assign")
        return [node]
      end

      markup = PartialSerializer.expression(value)
      markup = append_filters(markup, node.from.filters[folded..])
          rebuilt = new_variable(markup, node.from.line_number)
      assign_node = node.dup
      assign_node.instance_variable_set(:@from, rebuilt)
      [assign_node]
    end

    # ---- capture -------------------------------------------------------

    def transform_capture(node, scope)
      base = snapshot(scope)
      transformed = transform_block_body(node.body, scope)
      captured = static_text(transformed)
      unless captured.nil?
        scope[node.to] = captured
        return []
      end

      restore(scope, base)
      scope[node.to] = UNKNOWN
      record("capture #{node.to}", "capture")
      [node]
    end

    def static_text(nodes)
      output = +''
      nodes.each do |node|
        case node
        when ::String
          output << node
        when StaticOutput
          node.render_to_output_buffer(CaptureContext.new, output)
        else
          return nil
        end
      end
      output
    end

    class CaptureContext
      def apply_global_filter(value)
        value
      end
    end

    # ---- conditionals --------------------------------------------------

    def transform_conditional(node, scope)
      base = snapshot(scope)
      unless_node = node.is_a?(Unless)

      outcomes = node.blocks.map do |block|
        block.is_a?(ElseCondition) ? true : evaluate_block_condition(block, scope)
      end

      selected_index = select_index(outcomes, unless_node)
      if selected_index == :none
        restore(scope, base)
        return []
      elsif selected_index.is_a?(Integer)
        block = node.blocks[selected_index]
        restore(scope, base)
        return transform_block_body(block.attachment, scope)
      end

      restore(scope, base)

      # Unknown condition: retain all branches with their specialized bodies.
      specialized = specialize_conditional_branches(node, outcomes, base, unless_node)
      merge_conditional_scope(node, outcomes, base, scope, unless_node)
      [specialized]
    end

    def evaluate_block_condition(block, scope)
      value = @evaluator.evaluate_condition(block, scope)
      return :unknown if unknown?(value)

      Liquid::Utils.to_liquid_value(value) ? true : false
    end

    # Mirrors If/Unless runtime selection. Returns the index of the block that
    # is guaranteed to execute, or nil when the condition is not decidable.
    def select_index(outcomes, unless_node)
      if unless_node
        # unless: body of first block executes when first condition is false;
        # later elsif/else blocks execute only when first is true.
        return 0 if outcomes[0] == false

        if outcomes[0] == true
          rest = outcomes[1..]
          idx = rest.index(true)
          return idx + 1 if idx
          return :unknown_branch if rest.include?(:unknown)
        end
        return nil if outcomes[0] == :unknown
        return decidable_branch(outcomes)
      else
        return decidable_branch(outcomes)
      end
    end

    # Walks blocks as runtime does. A block is only selected when every block
    # preceding it is decidably false. An +:unknown+ outcome blocks selection
    # of everything after it.
    def decidable_branch(outcomes)
      outcomes.each_with_index do |outcome, index|
        return index if outcome == true
        return nil if outcome == :unknown
      end
      :none
    end

    def specialize_conditional_branches(node, _outcomes, base, _unless_node)
      specialized_bodies = {}
      branch_scopes = []

      node.blocks.each do |block|
        scope = base.dup
        nodes = transform_block_body(block.attachment, scope)
        specialized_bodies[block.attachment] = new_body(nodes, block.attachment.blank?)
        branch_scopes << scope
      end

      record_conditional(node)
      clone_block_tag(node, specialized_bodies)
    end

    def merge_conditional_scope(node, outcomes, base, scope, unless_node)
      branch_scopes = node.blocks.map.with_index do |block, index|
        next nil unless reachable_branch?(outcomes, index, unless_node)

        branch_scope = base.dup
        transform_block_body(block.attachment, branch_scope)
        branch_scope
      end.compact
      scope.replace(merge_scopes(base, *branch_scopes))
    end

    def reachable_branch?(outcomes, index, unless_node)
      if unless_node
        index.zero? ? outcomes[0] != true : outcomes[0] == true
      else
        true
      end
    end

    def record_conditional(node)
      node.blocks.each do |block|
        next if block.is_a?(ElseCondition)
        record(PartialSerializer.condition(block), "condition")
      end
    end

    # ---- case ----------------------------------------------------------

    def transform_case(node, scope)
      base = snapshot(scope)
      left = @evaluator.evaluate(node.left, scope)
      outcomes = node.blocks.map do |block|
        if block.is_a?(ElseCondition)
          :else
        else
          next :unknown if unknown?(left) || unknown?(@evaluator.evaluate(block.right, scope))

          Liquid::Utils.to_liquid_value(left) == Liquid::Utils.to_liquid_value(@evaluator.evaluate(block.right, scope))
        end
      end

      if outcomes.include?(:unknown)
        return retain_case(node, base, scope)
      end

      execute_else = true
      nodes = []
      node.blocks.each_with_index do |block, index|
        if block.is_a?(ElseCondition)
          nodes.concat(transform_block_body(block.attachment, scope)) if execute_else
        elsif outcomes[index] == true
          execute_else = false
          nodes.concat(transform_block_body(block.attachment, scope))
        end
      end
      nodes
    end

    def retain_case(node, base, scope)
      specialized_bodies = {}
      scopes = []
      node.blocks.each do |block|
        branch_scope = base.dup
        nodes = transform_block_body(block.attachment, branch_scope)
        specialized_bodies[block.attachment] = new_body(nodes, block.attachment.blank?)
        scopes << branch_scope
      end
      record(PartialSerializer.expression(node.left), "case")
      cloned = clone_case_tag(node, specialized_bodies)
      restore_after_case(base, scopes)
      scope.replace(base)
      [cloned]
    end

    def restore_after_case(base, scopes)
      # Case does not push a scope; merge alternatives conservatively.
      scopes.each { |branch_scope| base.merge!(branch_scope) { |_key, _old, _new| UNKNOWN } }
    end

    # ---- for -----------------------------------------------------------

    def transform_for(node, scope)
      base = snapshot(scope)
      segment, attributes_static = static_segment(node, scope)

      if attributes_static && segment
        if segment.length > @max_unrolled
          return retain_for(node, base, reason: "loop exceeds unroll cap")
        end
        return unroll_for(node, segment, base, scope)
      end

      retain_for(node, base)
    end

    def static_segment(node, scope)
      return [nil, false] if node.from == :continue

      collection = @evaluator.evaluate(node.collection_name, scope)
      return [nil, false] if unknown?(collection)

      from = if node.from == :continue
        :continue
      elsif node.from.nil?
        0
      else
        v = @evaluator.evaluate(node.from, scope)
        return [nil, false] if unknown?(v)

        v.nil? ? 0 : Utils.to_integer(v)
      end
      return [nil, false] if from == :continue

      to_value = if node.limit.nil?
        nil
      else
        lv = @evaluator.evaluate(node.limit, scope)
        return [nil, false] if unknown?(lv)

        lv.nil? ? nil : Utils.to_integer(lv)
      end

      resource_limits = ResourceLimits.new(@environment.default_resource_limits)
      segment = Utils.slice_collection_for_iteration(
        collection, from, to_value.nil? ? nil : to_value + from, resource_limits, use_range_to_a: true
      )
      collected = []
      segment.each { |item| collected << item }
      segment = collected
      segment.reverse! if node.instance_variable_get(:@reversed)
      [segment, true]
    rescue ::StandardError
      [nil, false]
    end

    def unroll_safe?(for_block)
      !contains_loop_dependency?(for_block.nodelist, depth: 0)
    end

    def contains_loop_dependency?(nodelist, depth:)
      nodelist.any? do |node|
        case node
        when ::String
          false
        when For
          # Nested loops own their break/continue and forloop.
          false
        when Break, Continue
          depth.zero?
        when TableRow, Ifchanged, Include, Render, Increment, Decrement, Cycle, Block, Tag
          true
        when Variable
          expression_uses_forloop?(node)
        when Echo
          expression_uses_forloop?(node.variable)
        when Assign
          expression_uses_forloop?(node.from)
        when Capture
          contains_loop_dependency?(node.nodelist, depth: depth)
        when If, Unless
          node.blocks.any? { |block| contains_loop_dependency?(block.attachment.nodelist, depth: depth) }
        when Case
          node.blocks.any? { |block| contains_loop_dependency?(block.attachment.nodelist, depth: depth) }
        else
          false
        end
      end
    end

    def expression_uses_forloop?(variable_node)
      return true if expression_node_uses_forloop?(variable_node.name)

      variable_node.filters.any? do |_name, args, kwargs|
        (args + (kwargs ? kwargs.values : [])).any? { |expr| expression_node_uses_forloop?(expr) }
      end
    end

    def expression_node_uses_forloop?(node)
      case node
      when VariableLookup
        root_name(node.name) == "forloop" || node.lookups.any? { |lookup| expression_node_uses_forloop?(lookup) }
      when RangeLookup
        expression_node_uses_forloop?(node.start_obj) || expression_node_uses_forloop?(node.end_obj)
      else
        false
      end
    end

    def root_name(name)
      name.is_a?(::String) ? name : nil
    end

    def unroll_for(node, segment, base, scope)
      for_block = node.for_block
      else_block = node.else_block

      unless unroll_safe?(for_block)
        return retain_for(node, base, reason: "body depends on loop machinery")
      end

      nodes = []
      if segment.empty?
        if else_block
          restore(scope, base)
          nodes.concat(transform_block_body(else_block, scope))
        end
        return nodes
      end

      iteration_scopes = []
      segment.each do |item|
        restore(scope, base)
        scope[node.variable_name] = StaticEvaluator.prepare_value(item)
        nodes.concat(transform_block_body(for_block, scope))
        iteration_scopes << snapshot(scope)
      end

      merged = merge_unroll_scopes(base, node.variable_name, iteration_scopes)
      scope.replace(merged)
      nodes
    end

    def merge_unroll_scopes(base, variable_name, iteration_scopes)
      merged = merge_scopes(base, *iteration_scopes)
      merged.delete(variable_name)
      merged
    end

    def retain_for(node, base, reason: nil)
      loop_scope = base.dup
      loop_scope[node.variable_name] = UNKNOWN
      loop_scope['forloop'] = UNKNOWN
      specialized_for = transform_block_body(node.for_block, loop_scope)
      bodies = { node.for_block => new_body(specialized_for, node.for_block.blank?) }
      if node.else_block
        specialized_else = transform_block_body(node.else_block, base.dup)
        bodies[node.else_block] = new_body(specialized_else, node.else_block.blank?)
      end
      base[node.variable_name] = UNKNOWN
      record(PartialSerializer.expression(node.collection_name), "loop", reason || "dynamic collection")
      cloned = clone_for_tag(node, bodies)
      [cloned]
    end

    # ---- cloning of retained tags --------------------------------------

    def new_body(nodes, blank)
      ResidualBlockBody.new(nodes, blank)
    end

    def clone_block_tag(node, bodies)
      clone = node.dup
      clone.instance_variable_set(:@blocks, node.blocks.dup)
      clone.blocks.each_with_index do |block, index|
        original_block = node.blocks[index]
        duplicated = dup_condition_chain(original_block)
        duplicated.attach(bodies.fetch(original_block.attachment, original_block.attachment))
        clone.blocks[index] = duplicated
      end
      clone
    end

    def dup_condition_chain(condition)
      duplicated = condition.dup
      child = condition.instance_variable_get(:@child_condition)
      if child
        duplicated.instance_variable_set(:@child_condition, dup_condition_chain(child))
      end
      duplicated
    end

    def clone_case_tag(node, bodies)
      clone = node.dup
      clone.instance_variable_set(:@blocks, node.blocks.dup)
      clone.blocks.each_with_index do |block, index|
        duplicated = block.dup
        duplicated.attach(bodies.fetch(node.blocks[index].attachment, node.blocks[index].attachment))
        clone.blocks[index] = duplicated
      end
      clone
    end

    def clone_for_tag(node, bodies)
      clone = node.dup
      clone.instance_variable_set(:@for_block, bodies.fetch(node.for_block, node.for_block))
      clone.instance_variable_set(:@else_block, bodies[node.else_block]) if node.else_block
      clone
    end

    # ---- residual ------------------------------------------------------

    def build_residual(nodes, blank)
      document = ResidualDocument.new(nodes, blank)
      Liquid::Template.allocate.tap do |template|
        template.send(:initialize_residual, document, @environment, @parse_context)
      end
    end

    def record(expression, kind, reason = nil)
      @retained << RetainedExpression.new(expression, kind, reason)
    end
  end
end
