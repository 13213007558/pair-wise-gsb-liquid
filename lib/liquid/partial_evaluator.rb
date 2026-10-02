# frozen_string_literal: true

module Liquid
  # Partially evaluates a template against the variables that are already
  # known ("static"), producing a residual template that can still be
  # rendered later with the remaining ("dynamic") variables.
  #
  # A typical use case is an email template whose brand configuration is
  # known when the template is published, while the recipient information
  # only becomes available when the email is sent:
  #
  #   evaluator = Liquid::PartialEvaluator.new(pure_filters: %w[upcase downcase])
  #   result = evaluator.evaluate(source, "brand" => { "name" => "Acme" })
  #   result.source        # => residual template source
  #   result.template      # => residual Liquid::Template
  #   result.preserved     # => expressions/tags that could not be folded, with reasons
  #
  # Folding rules:
  #
  # * Constants, conditions (+if+/+unless+/+case+) and bounded +for+ loops are
  #   folded when every value they depend on is known.
  # * Only filters explicitly registered via +pure_filters+ are executed
  #   during preprocessing. Any other filter leaves the expression untouched.
  # * Drop methods, +include+/+render+ (even with a static name), and custom
  #   or stateful tags (+cycle+, +increment+, +decrement+, +ifchanged+) are
  #   never executed during preprocessing; they are preserved verbatim.
  # * Branches whose condition cannot be decided statically are kept, never
  #   pruned: no sample input is ever used to guess an outcome.
  # * Values that cannot be materialized safely (Drops, Procs, arbitrary
  #   objects) make the surrounding expression "unknown" instead of being
  #   called.
  #
  # For any remaining variable assignments, rendering the residual template
  # produces the same output (and the same render-time errors) as rendering
  # the original template with the union of the known and remaining assigns.
  #
  # Note: output folded at preprocessing time is not passed through a global
  # filter (Registers +:global_filter+). If you rely on one, leave the
  # affected expressions to render time by not registering their filters as
  # pure.
  class PartialEvaluator
    DEFAULT_MAX_UNROLL = 100
    DEFAULT_MAX_EXPANSION = 100_000

    # Describes a node that could not be folded away during partial
    # evaluation, together with the reason. Useful to understand why
    # preprocessing did (or did not) pay off.
    class PreservedNode
      attr_reader :kind, :markup, :line_number, :reason, :details

      def initialize(kind:, markup:, line_number:, reason:, details: {})
        @kind        = kind
        @markup      = markup
        @line_number = line_number
        @reason      = reason
        @details     = details
      end

      def ==(other)
        other.is_a?(PreservedNode) && state == other.send(:state)
      end
      alias_method :eql?, :==

      def hash
        state.hash
      end

      def to_h
        {
          kind: kind,
          markup: markup,
          line_number: line_number,
          reason: reason,
          details: details,
        }
      end

      def inspect
        "#<#{self.class.name} #{kind} #{markup.inspect} line=#{line_number} reason=#{reason}>"
      end

      private

      def state
        [@kind, @markup, @line_number, @reason, @details]
      end
    end

    # The outcome of PartialEvaluator#evaluate.
    class Result
      # Residual template source, ready to be parsed and rendered with the
      # remaining assigns.
      attr_reader :source

      # Array of PreservedNode describing every expression/tag that was kept
      # for render time, and why.
      attr_reader :preserved

      # Hash with :variables and :tags counters of folded nodes.
      attr_reader :folded

      def initialize(source:, preserved:, folded:, parse_options:)
        @source        = source
        @preserved     = preserved
        @folded        = folded
        @parse_options = parse_options
      end

      # True when nothing was left for render time.
      def fully_evaluated?
        @preserved.empty?
      end

      # Parses the residual source into a renderable Liquid::Template.
      def template(**options)
        Liquid::Template.parse(@source, **@parse_options.merge(options))
      end
    end

    # Hash subclass used to represent +forloop+ drops statically. It is
    # traversable (forloop.index etc.) but is never output or compared
    # directly, so any whole-drop use stays at render time.
    # @api private
    class StaticForloopHash < Hash
    end

    attr_reader :environment, :pure_filters, :max_unroll, :max_expansion

    # @param environment [Liquid::Environment] environment used to resolve
    #   tags and filters.
    # @param pure_filters [Array<String, Symbol>] names of filters that are
    #   declared pure (no side effects, deterministic) and may be executed
    #   during preprocessing. Filters not listed here are never executed.
    # @param max_unroll [Integer] maximum number of iterations a +for+ loop
    #   may have to be unrolled.
    # @param max_expansion [Integer] maximum number of characters a single
    #   unrolled loop may add to the residual template.
    # @param strict_variables [Boolean] mirror of the render option; when
    #   true, missing lookups are left for render time so the same
    #   UndefinedVariable errors are produced.
    # @param error_mode [Symbol, nil] parser error mode override.
    def initialize(environment: Environment.default, pure_filters: [],
      max_unroll: DEFAULT_MAX_UNROLL, max_expansion: DEFAULT_MAX_EXPANSION,
      strict_variables: false, error_mode: nil)
      @environment      = environment
      @pure_filters     = pure_filters.map(&:to_s)
      @max_unroll       = max_unroll
      @max_expansion    = max_expansion
      @strict_variables = strict_variables
      @error_mode       = error_mode
    end

    def strict_variables?
      @strict_variables
    end

    # Registers an additional pure filter. Returns self so calls can be
    # chained.
    def register_pure_filter(name)
      @pure_filters << name.to_s unless @pure_filters.include?(name.to_s)
      self
    end

    # Folds +source+ against the known +assigns+ and returns a Result.
    #
    # Raises Liquid::SyntaxError for invalid templates, exactly like
    # Liquid::Template.parse would.
    def evaluate(source, assigns = {})
      source = source.to_s
      # Parse once up front so syntax errors surface exactly as they would
      # when parsing the original template.
      Liquid::Template.parse(source, **parse_options)

      static_assigns = {}
      assigns.each_pair { |key, value| static_assigns[key.to_s] = value }

      Folder.new(self, source, static_assigns).run
    end

    # @api private
    def parse_options
      options = { environment: @environment }
      options[:error_mode] = @error_mode if @error_mode
      options
    end
  end
end
