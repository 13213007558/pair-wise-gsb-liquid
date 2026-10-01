# frozen_string_literal: true

module Liquid
  module Specialized
    # Internal signal: this piece of the template cannot safely be folded.
    # StandardErrors raised while evaluating against known data are converted
    # to this signal, so specialization never triggers an error that the
    # original render would not have triggered at the same place.
    class CannotFold < StandardError; end

    # Sentinel stored in scope bindings when a variable may exist at render
    # time but its value is not statically known.
    DYNAMIC = Object.new.freeze

    # Tracks bindings during specialization.
    #
    # +read_scopes+ is the shadowing lookup chain (innermost first); a loop
    # pushes its loop variable on it. Assignments target the write scope,
    # which mirrors Liquid::Assign / Liquid::Capture writing to
    # scopes.last: an assignment inside a for-loop leaks out while the loop
    # variable itself is shadowed.
    #
    # A surviving conditional is handled by specializing each branch against
    # a fresh write scope (so branch-local folds still work) and afterwards
    # marking every name the branch assigned as dynamic in the enclosing
    # write scope.
    class ScopeChain
      attr_reader :read_scopes, :write_scope

      def initialize(read_scopes, write_scope = read_scopes.last)
        @read_scopes = read_scopes
        @write_scope = write_scope
      end

      # Push a shadowing read scope (loop variable). Writes still target the
      # same write scope, just like Liquid where {% assign %} uses scopes.last.
      def push_read(scope)
        ScopeChain.new([scope] + @read_scopes, @write_scope)
      end

      def write(key, value)
        @write_scope[key] = value
      end

      # Scope for specializing a branch that may not run. It reads through
      # the enclosing bindings but writes into a fresh hash so its assigns
      # cannot influence folds outside the conditional.
      def branch_scope
        ScopeChain.new([{}] + @read_scopes, {})
      end
    end

    # Read-only evaluator used only during specialization. It mirrors the
    # surface of Liquid::Context needed by parsed expressions and by the
    # filter pipeline, but operates strictly on plain Ruby data.
    class SpecContext
      attr_reader :environment, :strainer, :specializer

      def initialize(specializer, scope_chain)
        @specializer = specializer
        @environment = specializer.environment
        @scope_chain = scope_chain
        @strainer = specializer.build_strainer(self)
      end

      def scopes
        @scope_chain.read_scopes
      end

      def strict_variables
        false
      end

      def evaluate(object)
        object.respond_to?(:evaluate) ? object.evaluate(self) : object
      end

      def invoke(method, *args)
        @strainer.invoke(method, *args)
      end

      def apply_global_filter(obj)
        @specializer.apply_global_filter(obj)
      end

      def find_variable(key, raise_on_not_found: true)
        @scope_chain.read_scopes.each do |scope|
          return PlainLookup.resolve_value(scope[key], self) if scope.key?(key)
        end

        bindings = @specializer.initial_bindings
        if bindings.key?(key)
          return PlainLookup.resolve_value(bindings[key], self)
        end

        # Unknown at specialize time: may be provided per render.
        raise CannotFold
      end

      def lookup_and_evaluate(obj, key, raise_on_not_found: true)
        raise CannotFold if obj.is_a?(Proc)
        raise CannotFold unless obj.respond_to?(:[])

        if obj.respond_to?(:key?)
          return obj[key] if obj.key?(key)
        elsif key.is_a?(Integer) && obj.respond_to?(:fetch)
          return obj.fetch(key)
        end

        nil
      end
    end

    # Evaluates a VariableLookup against plain data using the same lookup
    # rules as Liquid::VariableLookup. DYNAMIC bindings and non-plain values
    # cause the enclosing fold to bail.
    module PlainLookup
      class << self
        def resolve_value(value, context)
          raise CannotFold if value.equal?(DYNAMIC)
          raise CannotFold unless context.specializer.plain_value?(value)
          value
        end

        def evaluate(lookup, context)
          name   = context.evaluate(lookup.name)
          object = context.find_variable(name)
          raise CannotFold unless context.specializer.plain_value?(object)

          lookup.lookups.each_index do |i|
            key = Liquid::Utils.to_liquid_value(context.evaluate(lookup.lookups[i]))
            object = step(object, key, lookup.lookup_command?(i), context)
            raise CannotFold unless context.specializer.plain_value?(object)
          end

          object
        end

        private

        def step(object, key, command, context)
          if object.respond_to?(:[]) &&
              ((object.respond_to?(:key?) && object.key?(key)) ||
               (object.respond_to?(:fetch) && key.is_a?(Integer)))
            context.lookup_and_evaluate(object, key)
          elsif command && object.respond_to?(key)
            object.send(key)
          elsif command && object.is_a?(String) && (key == "first" || key == "last")
            key == "first" ? (object[0] || "") : (object[-1] || "")
          else
            raise CannotFold
          end
        end
      end
    end

    # Main specialization transform.
    class Specializer
      attr_reader :environment, :initial_bindings, :pure_filter_names, :global_filter

      def initialize(environment:, known_assigns:, filters:, pure_filter_names:, global_filter:)
        @environment = environment
        @filters = filters || Const::EMPTY_ARRAY
        @global_filter = global_filter
        @pure_filter_names = (pure_filter_names || []).map(&:to_s)
        @pure_filter_names.each do |name|
          unless environment.strainer_template.invokable?(name)
            raise ArgumentError, "filter #{name.inspect} is declared pure but is not registered"
          end
        end

        @initial_bindings = {}
        (known_assigns || {}).each do |key, value|
          next unless key.is_a?(String) || key.is_a?(Symbol)
          duped = deep_dup_plain(value)
          @initial_bindings[key.to_s] = duped if plain_value?(duped)
        end
      end

      def specialize(body)
        builder = BodyBuilder.new(self)
        root_scope = {}
        specialize_nodelist(body.nodelist, builder, ScopeChain.new([root_scope], root_scope))
        builder.build
      end

      def build_strainer(context)
        @environment.create_strainer(context, @filters)
      end

      def apply_global_filter(obj)
        @global_filter.nil? ? obj : @global_filter.call(obj)
      end

      def plain_value?(value)
        case value
        when nil, true, false, Integer, Float
          true
        when String
          true
        when Array
          value.all? { |v| plain_value?(v) }
        when Hash
          value.all? { |k, v| (k.is_a?(String) || k.is_a?(Symbol)) && plain_value?(v) }
        else
          false
        end
      end

      def deep_dup_plain(value)
        case value
        when Array
          value.map { |v| deep_dup_plain(v) }
        when Hash
          value.each_with_object({}) { |(k, v), h| h[k] = deep_dup_plain(v) }
        when String
          +value.dup
        else
          value
        end
      end

      # ----- expression evaluation ------------------------------------------

      def eval_expression(expr, ctx)
        case expr
        when VariableLookup
          PlainLookup.evaluate(expr, ctx)
        when RangeLookup
          start_int = to_integer(eval_expression(expr.start_obj, ctx))
          end_int   = to_integer(eval_expression(expr.end_obj, ctx))
          (start_int..end_int)
        else
          expr
        end
      end

      def to_integer(input)
        case input
        when Integer
          input
        when NilClass, String
          input.to_i
        else
          Utils.to_integer(input)
        end
      end

      # Evaluates a Liquid::Variable's explicit filter pipeline. Returns the
      # final object (before the global filter and string rendering), or
      # raises CannotFold.
      def eval_pipeline(variable, ctx)
        obj = eval_expression(variable.name, ctx)

        variable.filters.each do |filter_name, filter_args, filter_kwargs|
          unless @pure_filter_names.include?(filter_name)
            raise CannotFold
          end
          parsed_args = filter_args.map { |expr| eval_expression(expr, ctx) }
          if filter_kwargs
            parsed_kwargs = {}
            filter_kwargs.each do |key, expr|
              parsed_kwargs[key] = eval_expression(expr, ctx)
            end
            parsed_args << parsed_kwargs
          end
          obj = ctx.invoke(filter_name, obj, *parsed_args)
          raise CannotFold unless plain_value?(obj)
        end

        obj
      end

      def render_obj(obj, output)
        case obj
        when NilClass
          # nothing
        when Array
          obj.each { |o| render_obj(o, output) }
        else
          output << Liquid::Utils.to_s(obj)
        end
      end

      def assign_score_of(val)
        if val.instance_of?(String)
          val.bytesize
        elsif val.instance_of?(Array)
          sum = 1
          val.each { |child| sum += assign_score_of(child) }
          sum
        elsif val.instance_of?(Hash)
          sum = 1
          val.each do |key, entry_value|
            sum += assign_score_of(key)
            sum += assign_score_of(entry_value)
          end
          sum
        else
          1
        end
      end

      # ----- AST traversal --------------------------------------------------

      def specialize_nodelist(nodelist, builder, scope)
        nodelist.each do |node|
          specialize_node(node, builder, scope)
        end
      end

      def specialize_node(node, builder, scope)
        case node
        when String
          builder.add_text(+node)
        when Variable
          specialize_output(node, builder, scope)
        when Echo
          specialize_echo(node, builder, scope)
        when Raw
          # Raw is left untouched so that blank?/error-suppression semantics
          # around it are preserved.
          builder.add_passthrough(node)
        when Assign
          specialize_assign(node, builder, scope)
        when Capture
          specialize_capture(node, builder, scope)
        when If
          specialize_if(node, builder, scope)
        when Case
          specialize_case(node, builder, scope)
        when For
          specialize_for(node, builder, scope)
        when TableRow
          specialize_table_row(node, builder, scope)
        else
          # comment, increment, decrement, cycle, include, render, break,
          # continue, ifchanged and any custom tags are preserved untouched.
          builder.add_passthrough(node)
          mark_include_leaks(node, scope)
        end
      rescue CannotFold, ::StandardError
        builder.add_passthrough(node)
        mark_include_leaks(node, scope)
      end

      def specialize_output(node, builder, scope)
        string = eval_output_pre_global(node, SpecContext.new(self, scope))
        builder.add_folded_text(string)
      rescue CannotFold, ::StandardError
        builder.add_variable(node)
      end

      def specialize_echo(node, builder, scope)
        string = eval_output_pre_global(node.variable, SpecContext.new(self, scope))
        builder.add_folded_text(string)
      rescue CannotFold, ::StandardError
        builder.add_passthrough(node)
      end

      # Renders the pipeline result without the global filter.
      def eval_output_pre_global(variable, ctx)
        obj = eval_pipeline(variable, ctx)
        raise CannotFold unless plain_value?(obj)
        buf = +''
        render_obj(obj, buf)
        buf
      end

      def specialize_assign(node, builder, scope)
        ctx = SpecContext.new(self, scope)
        value = eval_pipeline(node.from, ctx)
        raise CannotFold unless plain_value?(value)
        value = deep_dup_plain(value)
        stored_value = @global_filter ? @global_filter.call(value) : value
        raise CannotFold unless plain_value?(stored_value)
        builder.add_node(
          FusedAssign.new(
            node.to, value, assign_score_of(stored_value),
            line_number: node.line_number, global_filter: @global_filter
          )
        )
        scope.write(node.to, stored_value)
      rescue CannotFold, ::StandardError
        builder.add_passthrough(node)
        scope.write(node.to, DYNAMIC)
      end

      def specialize_capture(node, builder, scope)
        original_body = node.instance_variable_get(:@body)
        sub = BodyBuilder.new(self)
        specialize_nodelist(original_body.nodelist, sub, scope)
        if sub.static_only?
          value = +sub.materialized_string
          builder.add_node(FusedCapture.new(node.to, value, line_number: node.line_number))
          scope.write(node.to, value)
        else
          cloned = SpecializedTag.clone_block(node)
          cloned.replace_body(sub.build)
          builder.add_passthrough(cloned, weight: 1, write_checks: 0)
          scope.write(node.to, DYNAMIC)
        end
      end

      # ----- if / unless ----------------------------------------------------

      def specialize_if(node, builder, scope)
        selected = select_if_branch(node, scope)
        if selected
          sub = BodyBuilder.new(self)
          specialize_nodelist(node.blocks[selected].attachment.nodelist, sub, scope)
          # One render-score unit for the eliminated conditional tag itself.
          sub.add_weight_only(1)
          builder.merge(sub)
          return
        end

        cloned = SpecializedTag.clone_conditional(node)
        # Which branch runs is only known at render time: specialize every
        # branch against a throwaway write scope and mark every name the
        # branches assign as dynamic in the enclosing scope afterwards.
        branch_names = all_branch_leaks(node).keys
        cloned.blocks.each do |block|
          branch_scope = scope.branch_scope
          sub = BodyBuilder.new(self)
          specialize_nodelist(block.attachment.nodelist, sub, branch_scope)
          block.attach(sub.build)
        end
        builder.add_passthrough(cloned)
        branch_names.each { |name| scope.write(name, DYNAMIC) }
      end

      def select_if_branch(node, scope)
        ctx = SpecContext.new(self, scope)
        unless_node = node.is_a?(Unless)
        node.blocks.each_with_index do |block, i|
          result = Liquid::Utils.to_liquid_value(block.evaluate(ctx))
          result = !result if unless_node && i.zero? && !block.else?
          return i if result
        end
        nil
      rescue CannotFold, ::StandardError
        nil
      end

      def all_branch_leaks(node)
        leaks = {}
        node.blocks.each do |block|
          block.attachment.nodelist.each { |child| collect_leaks(child, leaks) }
        end
        leaks
      end

      def collect_leaks(node, leaks)
        case node
        when Assign
          leaks[node.to] = true
        when Capture
          leaks[node.to] = true
        when If
          node.blocks.each { |b| b.attachment.nodelist.each { |c| collect_leaks(c, leaks) } }
        when Case
          node.blocks.each { |b| b.attachment.nodelist.each { |c| collect_leaks(c, leaks) } }
        when For
          node.instance_variable_get(:@for_block).nodelist.each { |c| collect_leaks(c, leaks) }
          node.instance_variable_get(:@else_block)&.nodelist&.each { |c| collect_leaks(c, leaks) }
        when TableRow
          node.instance_variable_get(:@body).nodelist.each { |c| collect_leaks(c, leaks) }
        when Include
          node.attributes.each_key { |k| leaks[k] = true }
          alias_name = node.instance_variable_get(:@alias_name)
          leaks[alias_name] = true if alias_name
        end
      end

      # ----- case -----------------------------------------------------------

      def specialize_case(node, builder, scope)
        ctx = SpecContext.new(self, scope)
        executed_bodies = static_case_bodies(node, ctx)
        if executed_bodies
          sub = BodyBuilder.new(self)
          executed_bodies.uniq.each do |body|
            specialize_nodelist(body.nodelist, sub, scope)
          end
          sub.add_weight_only(1)
          builder.merge(sub)
          return
        end

        cloned = SpecializedTag.clone_conditional(node)
        branch_names = all_case_leaks(node).keys
        cloned.blocks.each do |block|
          branch_scope = scope.branch_scope
          sub = BodyBuilder.new(self)
          specialize_nodelist(block.attachment.nodelist, sub, branch_scope)
          block.attach(sub.build)
        end
        builder.add_passthrough(cloned)
        branch_names.each { |name| scope.write(name, DYNAMIC) }
      end

      # Returns the attachments that render given statically known data, or
      # nil if the decision depends on dynamic data.
      def static_case_bodies(node, ctx)
        bodies = []
        execute_else = true
        node.blocks.each do |block|
          if block.else?
            bodies << block.attachment if execute_else
            next
          end
          result = Liquid::Utils.to_liquid_value(block.evaluate(ctx))
          if result
            execute_else = false
            bodies << block.attachment
          end
        end
        bodies
      rescue CannotFold, ::StandardError
        nil
      end

      # ----- for / tablerow -------------------------------------------------

      def specialize_for(node, builder, scope)
        cloned = SpecializedTag.clone_block(node)
        original_for_body = cloned.for_body
        original_else_body = cloned.else_body

        # The loop variable and forloop are shadowed inside the body, but
        # {% assign %}/{% capture %} write through to the enclosing scope,
        # so the body uses a pushed read scope with the same write target.
        inner = { node.variable_name => DYNAMIC, 'forloop' => DYNAMIC }
        body_scope = scope.push_read(inner)
        sub = BodyBuilder.new(self)
        specialize_nodelist(original_for_body.nodelist, sub, body_scope)
        cloned.replace_for_body(sub.build)

        if original_else_body
          else_sub = BodyBuilder.new(self)
          specialize_nodelist(original_else_body.nodelist, else_sub, scope)
          cloned.replace_else_body(else_sub.build)
        end

        builder.add_passthrough(cloned)
        # Whether the body runs is unknown: mark names assigned anywhere in
        # the loop/else bodies dynamic in the enclosing scope.
        collect_body_leaks(original_for_body.nodelist).each_key do |name|
          scope.write(name, DYNAMIC)
        end
        if original_else_body
          collect_body_leaks(original_else_body.nodelist).each_key do |name|
            scope.write(name, DYNAMIC)
          end
        end
      end

      def specialize_table_row(node, builder, scope)
        cloned = SpecializedTag.clone_block(node)
        original_body = cloned.instance_variable_get(:@body)
        inner = { node.variable_name => DYNAMIC, 'tablerowloop' => DYNAMIC }
        body_scope = scope.push_read(inner)
        sub = BodyBuilder.new(self)
        specialize_nodelist(original_body.nodelist, sub, body_scope)
        cloned.replace_body(sub.build)
        builder.add_passthrough(cloned)
        collect_body_leaks(original_body.nodelist).each_key do |name|
          scope.write(name, DYNAMIC)
        end
      end

      def collect_body_leaks(nodelist, leaks = {})
        nodelist.each do |node|
          collect_leaks(node, leaks)
        end
        leaks
      end

      # ----- passthrough side effects --------------------------------------

      def mark_include_leaks(node, scope)
        return unless node.is_a?(Include)
        node.attributes.each_key { |key| scope.write(key, DYNAMIC) }
        alias_name = node.instance_variable_get(:@alias_name)
        scope.write(alias_name, DYNAMIC) if alias_name
      end
    end
  end
end
