# frozen_string_literal: true

module Liquid
  # Evaluates Liquid expressions against a set of partially known variables
  # without touching Drops, registers, filesystems or any render-time state.
  #
  # Lookups that depend on a variable whose value is not known at
  # preprocessing time return {StaticEvaluator::UNKNOWN}. Evaluation errors
  # that may depend on render-time data are also reported as UNKNOWN, so the
  # surrounding expression is preserved verbatim in the residual template and
  # is evaluated normally at render time (preserving both output and exception
  # semantics).
  #
  # Only filter names explicitly registered as pure on the environment are
  # executed; any other filter causes the rest of the filter chain to be
  # reported as UNKNOWN.
  #
  # @api private
  class StaticEvaluator
    # Sentinel for a value that cannot be determined at preprocessing time.
    # Frozen so it can safely be shared across frozen scope hashes.
    UNKNOWN = Class.new do
      def freeze
        self
      end

      def to_s
        "Liquid::StaticEvaluator::UNKNOWN"
      end
    end.new.freeze

    class << self
      # Returns true if +value+ is safe to inspect and fold at preprocessing
      # time. Only plain data structures composed of Liquid literals are
      # considered static; Drops, Procs, arbitrary Ruby objects, symbols and
      # ranges produced by user objects are all left for render time.
      def static_value?(value)
        case value
        when nil, true, false, Integer, Float, String
          true
        when ::Range
          static_value?(value.begin) && static_value?(value.end)
        when Array
          value.all? { |entry| static_value?(entry) }
        when Hash
          value.all? { |key, val| static_value?(key) && static_value?(val) }
        else
          false
        end
      end

      # Recursively freezes a known value and converts anything attached to it
      # that is not a plain static value into UNKNOWN.
      def prepare_value(value)
        case value
        when nil, true, false, Integer, Float
          value
        when ::Range
          value.begin.is_a?(Integer) && value.end.is_a?(Integer) ? value : UNKNOWN
        when String
          value.dup.freeze
        when Array
          value.map { |entry| prepare_value(entry) }.freeze
        when Hash
          value.each_with_object({}) do |(key, val), memo|
            next unless static_value?(key)

            memo[static_key(key)] = prepare_value(val)
          end.freeze
        else
          UNKNOWN
        end
      end
    end

    class << self
      private

      def static_key(key)
        key.is_a?(String) ? key.dup.freeze : key
      end
    end

    def initialize(environment:, pure_filters: nil, strict_variables: false)
      @environment = environment
      @pure_filters = pure_filters || environment.pure_filters
      @strict_variables = strict_variables
    end

    # Evaluates a parsed expression node. Returns UNKNOWN for anything that
    # cannot be proven without render-time information.
    def evaluate(node, scope)
      case node
      when nil, true, false, Integer, Float, String
        node
      when VariableLookup
        evaluate_lookup(node, scope)
      when RangeLookup
        evaluate_range(node, scope)
      when ::Range
        node.begin.is_a?(Integer) && node.end.is_a?(Integer) ? node : UNKNOWN
      else
        UNKNOWN
      end
    rescue UnknownError
      UNKNOWN
    rescue Liquid::UndefinedVariable
      raise if @strict_variables

      UNKNOWN
    end

    # Evaluates a {Condition} chain against a known scope.
    def evaluate_condition(condition, scope)
      current = condition
      result = nil

      loop do
        result = interpret_comparison(current.left, current.right, current.operator, scope)
        return UNKNOWN if unknown?(result)

        case current.instance_variable_get(:@child_relation)
        when :or
          break if Liquid::Utils.to_liquid_value(result)
        when :and
          break unless Liquid::Utils.to_liquid_value(result)
        else
          break
        end
        current = current.instance_variable_get(:@child_condition)
        break if current.nil?
      end

      result
    rescue UnknownError
      UNKNOWN
    end

    # Runs an allow-listed filter against fully known arguments. Returns UNKNOWN
    # if any argument is unknown, the filter is not registered as pure, or the
    # filter raises.
    def apply_filter(name, input, args, kwargs)
      return UNKNOWN unless @pure_filters.allow?(name)
      return UNKNOWN if unknown?(input) || args.any? { |arg| unknown?(arg) }
      return UNKNOWN if kwargs && kwargs.any? { |_key, val| unknown?(val) }

      result = invoke_filter(name, input, args, kwargs)
      result = result.to_liquid
      self.class.prepare_value(result)
    rescue ::StandardError
      UNKNOWN
    end

    def unknown?(value)
      value.equal?(UNKNOWN)
    end

    private

    class UnknownError < StandardError; end

    def known!(value)
      raise UnknownError if unknown?(value)

      value
    end

    def evaluate_lookup(node, scope)
      name = node.name.is_a?(VariableLookup) ? evaluate(node.name, scope) : node.name
      known!(name)

      unless scope.key?(name)
        return UNKNOWN unless @strict_variables

        raise Liquid::UndefinedVariable, "undefined variable #{name}"
      end

      object = scope.fetch(name)
      return UNKNOWN if unknown?(object)

      node.lookups.each_with_index do |lookup, index|
        key = evaluate(lookup, scope)
        known!(key)
        return UNKNOWN if unknown?(object)
        object = descend(object, key, node.lookup_command?(index))
      end

      return UNKNOWN if unknown?(object)

      self.class.prepare_value(object)
    end

    def descend(object, key, command)
      if object.is_a?(Hash) && object.key?(key)
        value = object[key]
        known!(value)
        value
      elsif object.is_a?(Array) && key.is_a?(Integer)
        object.fetch(key, nil)
      elsif command && !object.respond_to?(:[]) && object.respond_to?(key)
        # Mirrors VariableLookup: .size/.first/.last command fallback on
        # objects that do not expose indexing.
        object.public_send(key)
      elsif command && object.is_a?(String) && (key == 'first' || key == 'last')
        key == 'first' ? (object[0] || '') : (object[-1] || '')
      elsif command && object.respond_to?(key)
        object.public_send(key)
      elsif object.respond_to?(:[]) && object.respond_to?(:key?) && object.key?(key)
        value = object[key]
        known!(value)
        value
      else
        nil
      end
    rescue UnknownError
      raise
    rescue ::StandardError
      UNKNOWN
    end

    def evaluate_range(node, scope)
      start_value = known!(evaluate(node.start_obj, scope))
      end_value = known!(evaluate(node.end_obj, scope))

      start_int = range_bound(start_value)
      end_int = range_bound(end_value)
      raise UnknownError if start_int.nil? || end_int.nil?

      start_int..end_int
    end

    def range_bound(value)
      case value
      when Integer
        value
      when String
        Integer(value, 10) rescue value.to_i
      when nil
        0
      else
        Liquid::Utils.to_integer(value)
      end
    end

    def interpret_comparison(left, right, operator, scope)
      if left.is_a?(Condition::MethodLiteral)
        right_value = known!(evaluate(right, scope))
        return evaluate_method_literal(left, right_value)
      end
      if right.is_a?(Condition::MethodLiteral)
        left_value = known!(evaluate(left, scope))
        return evaluate_method_literal(right, left_value)
      end

      left_value = known!(evaluate(left, scope))
      return Liquid::Utils.to_liquid_value(left_value) if operator.nil?

      right_value = known!(evaluate(right, scope))
      left_value = Liquid::Utils.to_liquid_value(left_value)
      right_value = Liquid::Utils.to_liquid_value(right_value)

      operation = Condition.operators[operator] || raise(Liquid::ArgumentError, "Unknown operator #{operator}")
      if operation.respond_to?(:call)
        operation.call(Condition.new(left_value, operator, right_value), left_value, right_value)
      elsif left_value.respond_to?(operator) && right_value.respond_to?(operator) &&
          !left_value.is_a?(Hash) && !right_value.is_a?(Hash)
        left_value.public_send(operator, right_value)
      end
    end

    def evaluate_method_literal(literal, value)
      case literal.method_name
      when :blank?
        blank?(value)
      when :empty?
        empty?(value)
      else
        false
      end
    end

    def blank?(value)
      case value
      when nil, false
        true
      when true, Numeric
        false
      when String
        value.empty? || value.match?(/\A\s*\z/)
      when Array, Hash
        value.empty?
      else
        value.respond_to?(:empty?) ? value.empty? : false
      end
    end

    def empty?(value)
      case value
      when String, Array, Hash
        value.empty?
      else
        value.respond_to?(:empty?) ? value.empty? : false
      end
    end

    def invoke_filter(name, input, args, kwargs)
      strainer = @environment.create_strainer(NilContext.new)
      call_args = args.dup
      call_args << kwargs if kwargs
      strainer.send(name, input, *call_args)
    end

    # Minimal context object handed to pure filters. Pure filters must not use
    # it; it exists only so filters that merely accept an (unused) context via
    # the InputIterator machinery can be invoked without a full render context.
    class NilContext
      def resource_limits
        ResourceLimits.new
      end

      def strict_variables
        false
      end

      def strict_filters
        false
      end

      def [](_key)
        nil
      end
    end
  end
end
