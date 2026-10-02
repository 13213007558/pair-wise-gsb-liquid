# frozen_string_literal: true

module Liquid
  # Diagnostic information produced by {Template#specialize}. It records every
  # expression that the partial evaluator could not collapse, making it
  # possible to see why preprocessing did not eliminate work.
  class SpecializationInfo
    # @return [Array<RetainedExpression>] expressions still present in the
    #   residual template, in template order.
    attr_reader :retained_expressions

    def initialize(retained_expressions = [])
      @retained_expressions = retained_expressions
    end

    # @return [Hash{String => Integer}] number of retained expressions grouped
    #   by their kind (+output+, +condition+, +loop+, ...).
    def summary
      @retained_expressions.each_with_object(Hash.new(0)) do |retained, counts|
        counts[retained.kind] += 1
      end
    end

    def retained_count
      @retained_expressions.length
    end

    alias_method :size, :retained_count

    # @return [Array<String>] the source of every retained expression
    def expressions
      @retained_expressions.map(&:expression)
    end

    def to_h
      {
        retained_count: retained_count,
        summary: summary,
        retained_expressions: @retained_expressions.map { |entry| { expression: entry.expression, kind: entry.kind } },
      }
    end
  end

  # A single expression that could not be preprocessed away.
  RetainedExpression = Struct.new(:expression, :kind, :reason) do
    def initialize(expression, kind, reason = nil)
      super(expression.to_s, kind.to_s, reason)
    end
  end
end
