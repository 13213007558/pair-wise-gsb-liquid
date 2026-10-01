# frozen_string_literal: true

module Liquid
  class Specializer
    # A read-only, side-effect-free stand in for Liquid::Context during
    # specialization. It evaluates the same parsed expression objects
    # (VariableLookup, RangeLookup, literals...) against a lexical stack of
    # frames, each a pair of (static bindings hash, set of dynamic names).
    #
    # Any value that is not ordinary "plain" data (Drops, Procs, custom objects),
    # any unknown variable, and any declared non-pure operation raises
    # DynamicExpression so the driver can keep that expression for render time.
    class StaticContext
      # Raised internally by the static evaluator whenever an expression cannot
      # be reduced at specialization time without risking divergent semantics.
      #
      # This always bubbles out to the transformation driver, which
      # residualizes the surrounding expression; it is never raised to callers
      # of Template#specialize.
      class DynamicExpression < StandardError
        INSTANCE = new
      end

      def initialize
        @frames = []
      end

      attr_reader :frames

      def push_frame(static_bindings, dynamic_names)
        @frames.push([static_bindings, dynamic_names])
      end

      def pop_frame
        @frames.pop
      end

      def strict_variables
        false
      end

      # Context-like evaluation entry point, used by RangeLookup and VariableLookup.
      def evaluate(object)
        case object
        when nil, true, false, Integer, Float, String, Symbol, Array, Hash
          object
        when VariableLookup
          evaluate_variable_lookup(object)
        when RangeLookup
          evaluate_range_lookup(object)
        when Range
          object
        when Condition::MethodLiteral
          object
        else
          # Only the literal types above are produced by the Liquid parser
          # outside of VariableLookup / RangeLookup.
          raise DynamicExpression::INSTANCE
        end
      end

      # Mirrors Liquid::Context#find_variable + VariableLookup#evaluate for
      # plain values only.
      def evaluate_variable_lookup(lookup)
        name = evaluate(lookup.name)
        object = find_static_variable(name)

        lookup.lookups.each_index do |i|
          # Any lookup expression that is not fully static forces the whole
          # variable lookup to be residualized. In particular, freezing plain
          # collections would otherwise break the runtime key-missing path.
          key = evaluate(lookup.lookups[i])
          key = Liquid::Utils.to_liquid_value(key)

          if object.respond_to?(:[]) &&
              ((object.respond_to?(:key?) && object.key?(key)) ||
               (object.respond_to?(:fetch) && key.is_a?(Integer)))
            object = lookup_plain(object[key])
          elsif lookup.lookup_command?(i) && object.respond_to?(key)
            # size / first / last commands. Only safe for plain collections.
            object = lookup_plain(object.public_send(key))
          elsif lookup.lookup_command?(i) && object.is_a?(String) && (key == "first" || key == "last")
            object = key == "first" ? (object[0] || "") : (object[-1] || "")
          else
            # Either the key is missing (which at render time may resolve to
            # nil or, with strict_variables, raise) or the lookup is dynamic.
            # Residualize so the real runtime context decides.
            raise DynamicExpression::INSTANCE
          end
        end

        object
      end

      def evaluate_range_lookup(range_lookup)
        start_int = range_to_integer(evaluate(range_lookup.start_obj))
        end_int   = range_to_integer(evaluate(range_lookup.end_obj))
        start_int..end_int
      end

      # --- Condition semantics -------------------------------------------------

      # Evaluates an entire and/or Condition chain exactly like
      # Liquid::Condition#evaluate, but without ever short-circuiting past an
      # operand that the runtime would have reached: raises DynamicExpression
      # as soon as the result is undecidable. Returns the truthy result.
      def evaluate_condition(condition)
        loop do
          result = interpret_condition(condition.left, condition.right, condition.operator)

          case condition.instance_variable_get(:@child_relation)
          when :or
            return Liquid::Utils.to_liquid_value(result) if Liquid::Utils.to_liquid_value(result)
          when :and
            return Liquid::Utils.to_liquid_value(result) unless Liquid::Utils.to_liquid_value(result)
          else
            return Liquid::Utils.to_liquid_value(result)
          end
          condition = condition.instance_variable_get(:@child_condition)
        end
      end

      private

      def range_to_integer(input)
        case input
        when Integer
          input
        when NilClass, String
          input.to_i
        else
          Liquid::Utils.to_integer(input)
        end
      end

      # Replicates Liquid::Condition#interpret_condition for plain values.
      def interpret_condition(left_expr, right_expr, op)
        if op.nil?
          return evaluate(left_expr)
        end

        left  = Liquid::Utils.to_liquid_value(evaluate(left_expr))
        right = Liquid::Utils.to_liquid_value(evaluate(right_expr))

        case op
        when '=='
          equal_variables(left, right, negate: false)
        when '!=', '<>'
          equal_variables(left, right, negate: true)
        when 'contains'
          contains?(left, right)
        when '<', '>', '>=', '<='
          if left.respond_to?(op) && right.respond_to?(op) && !left.is_a?(Hash) && !right.is_a?(Hash)
            begin
              left.public_send(op, right)
            rescue ::ArgumentError => e
              raise Liquid::ArgumentError, e.message
            end
          end
        else
          raise Liquid::ArgumentError, "Unknown operator #{op}"
        end
      end

      def equal_variables(left, right, negate:)
        result = if left.is_a?(Condition::MethodLiteral)
          call_method_literal(left, right)
        elsif right.is_a?(Condition::MethodLiteral)
          call_method_literal(right, left)
        else
          left == right
        end
        negate ? !result : result
      end

      def call_method_literal(literal, value)
        method_name = literal.method_name
        if value.respond_to?(method_name)
          value.public_send(method_name)
        elsif method_name == :blank?
          liquid_blank?(value)
        elsif method_name == :empty?
          liquid_empty?(value)
        else
          false
        end
      end

      def liquid_blank?(value)
        case value
        when NilClass, FalseClass
          true
        when TrueClass, Numeric
          false
        when String
          value.empty? || value.match?(/\A\s*\z/)
        when Array, Hash
          value.empty?
        else
          value.respond_to?(:empty?) ? value.empty? : false
        end
      end

      def liquid_empty?(value)
        case value
        when String, Array, Hash
          value.empty?
        else
          value.respond_to?(:empty?) ? value.empty? : false
        end
      end

      def contains?(left, right)
        if left && right && left.respond_to?(:include?)
          right = right.to_s if left.is_a?(String)
          left.include?(right)
        else
          false
        end
      end

      # Looks up a root variable across the lexical stack, innermost first.
      # A dynamic binding only shadows static bindings in frames further out.
      def find_static_variable(key)
        found = false
        value = nil
        index = 0
        while index < @frames.length
          static_bindings, dynamic_names = @frames[index]
          if dynamic_names.include?(key)
            raise DynamicExpression::INSTANCE
          elsif !found && static_bindings.key?(key)
            found = true
            value = static_bindings[key]
          end
          index += 1
        end

        raise DynamicExpression::INSTANCE unless found
        lookup_plain(value)
      end

      # Plain values are reused; anything capable of carrying behaviour or
      # side effects (Drops, Procs, ...) forces residualization.
      def lookup_plain(value)
        if Specializer.plain?(value)
          value
        else
          raise DynamicExpression::INSTANCE
        end
      end
    end
  end
end
