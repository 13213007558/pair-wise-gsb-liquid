# frozen_string_literal: true

require 'strscan'

module Liquid
  # @liquid_public_docs
  # @liquid_type tag
  # @liquid_category variable
  # @liquid_name with
  # @liquid_summary
  #   Binds variables by destructuring an expression inside a scoped block.
  # @liquid_description
  #   The `with` tag destructures an array or object into local variables that are
  #   only available inside the block. Variables are bound using nested array
  #   patterns, object key patterns, and a trailing `*rest` pattern that collects
  #   the remaining items.
  #
  #   A sub-pattern can be followed by `= default_expr` to provide a value used
  #   when the matching item or key is missing. An explicit `nil` is *not*
  #   considered missing, so defaults are skipped for it.
  #
  #   If any part of the pattern does not match the input value, the whole binding
  #   fails atomically: none of the pattern variables are assigned and rendering
  #   is aborted with an error naming the failing pattern path. When the block
  #   ends, its scope is popped, restoring any outer variable with the same name.
  #
  #   ```liquid
  #   {% with [user, perms = empty_perms] = payload %}
  #     {{ user.name }} can {{ perms | join: ', ' }}
  #   {% endwith %}
  #   ```
  #
  #   ```liquid
  #   {% with { name: title = 'Guest', perms: [first = 'none', *rest] } = payload %}
  #     {{ title }}: {{ first }}, +{{ rest.size }}
  #   {% endwith %}
  #   ```
  # @liquid_syntax
  #   {% with pattern = expression %}
  #     expression
  #   {% endwith %}
  class With < Block
    # Sentinel object used internally to distinguish an explicit `nil` from a
    # missing array index or object key during matching.
    module MISSING
    end

    def initialize(tag_name, markup, options)
      super
      parser = PatternParser.new(markup.to_s, parse_context)
      @pattern = parser.parse_root
      @value   = parser.value_variable
    end

    attr_reader :pattern, :value

    def render_to_output_buffer(context, output)
      value = @value.render(context)
      bindings = {}
      @pattern.match(value, context, parse_context.locale, [], bindings)

      context.stack do
        context.merge(bindings)
        @body.render_to_output_buffer(context, output)
      end

      output
    end

    class ParseTreeVisitor < Liquid::ParseTreeVisitor
      def children
        [@node.value] + @node.pattern.all_expressions
      end
    end

    # Shared helpers for pattern tree nodes.
    module PatternNode
      private

      def fail_match!(locale, path, reason_key)
        location = if path.empty?
          '$'
        else
          path.map { |segment| format_path_segment(segment) }.join
        end

        raise PatternMatchError, locale.t(
          "errors.pattern.match_failed",
          path: location,
          reason: locale.t("errors.pattern.#{reason_key}"),
        )
      end

      def format_path_segment(segment)
        case segment
        when Integer then "[#{segment}]"
        when :rest   then '[*]'
        else              ".#{segment}"
        end
      end
    end

    # Binds a single variable, optionally with a default expression.
    class LeafPattern
      include PatternNode

      attr_reader :name, :default_expr, :variables, :all_expressions

      def initialize(name, default_expr = nil)
        @name = name
        @default_expr = default_expr
        @variables = [name].freeze
        @all_expressions = default_expr ? [default_expr].freeze : Const::EMPTY_ARRAY
      end

      def with_default(default_expr)
        LeafPattern.new(@name, default_expr)
      end

      def match(value, context, locale, path, bindings)
        if value.equal?(MISSING)
          value = if @default_expr
            @default_expr.render(context)
          else
            fail_match!(locale, path, :missing)
          end
        end

        bindings[@name] = value
      end
    end

    # Matches an Array (or array-like collection) by position.
    class ArrayPattern
      include PatternNode

      attr_reader :elements, :rest, :default_expr

      def initialize(elements, rest, default_expr = nil)
        @elements = elements
        @rest = rest
        @default_expr = default_expr
        @variables = elements.flat_map(&:variables) + (rest ? rest.variables : [])
        @all_expressions = elements.flat_map(&:all_expressions) +
          (rest ? rest.all_expressions : []) +
          (default_expr ? [default_expr] : [])
        @variables.freeze
        @all_expressions.freeze
      end

      attr_reader :variables, :all_expressions

      def with_default(default_expr)
        ArrayPattern.new(@elements, @rest, default_expr)
      end

      def match(value, context, locale, path, bindings)
        if value.equal?(MISSING)
          value = if @default_expr
            @default_expr.render(context)
          else
            fail_match!(locale, path, :missing)
          end
        end

        unless value.is_a?(Array)
          fail_match!(locale, path, :not_array)
        end

        # Matching proceeds element by element so that a missing element fails at
        # its concrete index (where its own default may still save the match). We
        # only reject up front when the array has more elements than the pattern
        # can bind and there is no rest to collect them.
        if @rest.nil? && value.length > @elements.length
          fail_match!(locale, path, :size_mismatch)
        end

        @elements.each_with_index do |element, index|
          item = value.fetch(index, MISSING)
          element.match(item, context, locale, path + [index], bindings)
        end

        if @rest
          slice_start = [@elements.length, value.length].min
          @rest.match(value[slice_start..] || [], context, locale, path + [:rest], bindings)
        end
      end
    end

    # Matches a Hash (or hash-like object) by key.
    class ObjectPattern
      include PatternNode

      attr_reader :pairs, :rest, :default_expr

      def initialize(pairs, rest, default_expr = nil)
        @pairs = pairs
        @rest = rest
        @default_expr = default_expr
        @variables = pairs.flat_map { |_key, pattern| pattern.variables } +
          (rest ? rest.variables : [])
        @all_expressions = pairs.flat_map { |_key, pattern| pattern.all_expressions } +
          (rest ? rest.all_expressions : []) +
          (default_expr ? [default_expr] : [])
        @variables.freeze
        @all_expressions.freeze
      end

      attr_reader :variables, :all_expressions

      def with_default(default_expr)
        ObjectPattern.new(@pairs, @rest, default_expr)
      end

      def match(value, context, locale, path, bindings)
        if value.equal?(MISSING)
          value = if @default_expr
            @default_expr.render(context)
          else
            fail_match!(locale, path, :missing)
          end
        end

        unless value.is_a?(Hash)
          fail_match!(locale, path, :not_object)
        end

        matched_keys = []

        @pairs.each do |key, pattern|
          item = value.key?(key) ? value.fetch(key) : MISSING
          matched_keys << key
          pattern.match(item, context, locale, path + [key], bindings)
        end

        if @rest
          remaining = value.reject { |key, _value| matched_keys.include?(key) }
          @rest.match(remaining, context, locale, path + [:rest], bindings)
        end
      end
    end

    # Parses the `with` tag markup into a pattern tree and the value expression.
    #
    # Grammar:
    #   markup   := pattern '=' expression
    #   pattern  := identifier
    #             | '[' element (',' element)* [','] ']'
    #             | '{' pair (',' pair)* [','] '}'
    #   element  := rest | pattern ['=' expression]
    #   pair     := (identifier | string) ':' element
    #   rest     := '*' identifier
    class PatternParser
      IDENTIFIER = /\A[a-zA-Z_][a-zA-Z0-9_]*\??/
      WHITESPACE = /[ \t\r\n\f]*/

      def initialize(markup, parse_context)
        @scanner = StringScanner.new(markup)
        @parse_context = parse_context
        @seen_variables = {}
        @value_variable = nil
      end

      def parse_root
        skip_whitespace
        raise_syntax_error('rest_at_root') if @scanner.peek(1) == '*'

        pattern = parse_pattern(element: false)
        skip_whitespace
        consume!('=', 'root_expected_equals')
        expr = capture_root_expression
        raise_syntax_error('empty_value') if expr.strip.empty?

        @value_variable = Variable.new(expr.strip, @parse_context)
        expect_eos
        pattern
      end

      attr_reader :value_variable

      private

      # Parses a pattern. When `element: true`, a trailing default expression
      # (`= expr`) is allowed on the pattern. A bare `*rest` pattern is only
      # consumed directly by the array/object element loops via {#parse_rest},
      # which enforces the trailing-position rule.
      def parse_pattern(element: false)
        skip_whitespace
        raise_syntax_error('rest_not_last') if @scanner.peek(1) == '*'

        pattern =
          if @scanner.peek(1) == '['
            parse_array
          elsif @scanner.peek(1) == '{'
            parse_object
          else
            name = parse_identifier
            register_variable!(name)
            LeafPattern.new(name)
          end

        pattern = attach_default!(pattern) if element
        pattern
      end

      def parse_array
        consume!('[')
        elements = []
        rest = nil

        skip_whitespace
        unless @scanner.peek(1) == ']'
          loop do
            skip_whitespace
            break if @scanner.peek(1) == ']'

            if @scanner.peek(1) == '*'
              raise_syntax_error('element_after_rest') unless rest.nil?
              rest = parse_rest(']')
            else
              elements << parse_pattern(element: true)
            end

            skip_whitespace
            if @scanner.peek(1) == ','
              @scanner.get_byte
              skip_whitespace
              break if @scanner.peek(1) == ']'
            else
              break
            end
          end
        end

        consume!(']', 'unclosed_array')
        ArrayPattern.new(elements, rest)
      end

      def parse_object
        consume!('{')
        pairs = {}
        rest = nil

        skip_whitespace
        unless @scanner.peek(1) == '}'
          loop do
            skip_whitespace
            break if @scanner.peek(1) == '}'

            if @scanner.peek(1) == '*'
              raise_syntax_error('element_after_rest') unless rest.nil?
              rest = parse_rest('}')
            else
              key = parse_key
              raise_syntax_error('duplicate_key', key: key) if pairs.key?(key)
              skip_whitespace
              consume!(':', 'object_expected_colon')
              skip_whitespace
              pairs[key] = if @scanner.peek(1) == '*'
                raise_syntax_error('element_after_rest') unless rest.nil?
                parse_rest('}')
              else
                parse_pattern(element: true)
              end
            end

            skip_whitespace
            if @scanner.peek(1) == ','
              @scanner.get_byte
              skip_whitespace
              break if @scanner.peek(1) == '}'
            else
              break
            end
          end
        end

        consume!('}', 'unclosed_object')
        ObjectPattern.new(pairs, rest)
      end

      def parse_rest(closing)
        @scanner.get_byte # consume '*'
        name = parse_identifier
        skip_whitespace
        if @scanner.peek(1) == '='
          raise_syntax_error('rest_with_default')
        elsif !rest_is_terminal?(closing)
          raise_syntax_error('rest_not_last')
        end
        register_variable!(name)
        LeafPattern.new(name)
      end

      # A `*rest` element is only valid as the last element, i.e. it must be
      # followed by the closing bracket of the pattern it belongs to, or by a
      # trailing comma immediately before that closing bracket.
      def rest_is_terminal?(closing)
        char = @scanner.peek(1)
        return true if char == closing || char.nil?

        if char == ','
          saved = @scanner.pos
          @scanner.get_byte
          skip_whitespace
          next_char = @scanner.peek(1)
          @scanner.pos = saved
          return next_char == closing
        end

        false
      end

      def parse_key
        if @scanner.peek(1) == "'" || @scanner.peek(1) == '"'
          parse_string
        else
          parse_identifier
        end
      end

      def parse_identifier
        token = @scanner.scan(IDENTIFIER)
        raise_syntax_error('expected_identifier') unless token
        token
      end

      def parse_string
        quote = @scanner.get_byte
        body = @scanner.scan_until(/(?=#{Regexp.escape(quote)})/)
        raise_syntax_error('unclosed_string') if body.nil?
        @scanner.get_byte # consume closing quote
        body
      end

      def attach_default!(pattern)
        skip_whitespace
        return pattern unless @scanner.peek(1) == '='

        @scanner.get_byte # consume '='
        expr = capture_expression
        raise_syntax_error('empty_default') if expr.strip.empty?

        default = Variable.new(expr.strip, @parse_context)
        pattern.with_default(default)
      end

      # Captures the root value expression: everything after `=` up to the end
      # of the markup (honoring quoted strings). Liquid has no array/object
      # literals, so stray brackets inside the expression are reported by the
      # Liquid expression parser that consumes the captured markup.
      def capture_root_expression
        start = @scanner.pos

        until @scanner.eos?
          char = @scanner.peek(1)
          if char == "'" || char == '"'
            skip_string
          else
            @scanner.pos += 1
          end
        end

        @scanner.string.byteslice(start, @scanner.pos - start)
      end

      # Captures a Liquid expression up to a top-level ',' or a bracket that
      # closes the enclosing pattern, honoring nested brackets and quoted
      # strings. (`{` and `}` are tracked for nested object patterns; a stray
      # brace that does not belong to a pattern pair is caught afterwards when
      # the expression is parsed as a Liquid variable.)
      def capture_expression
        start = @scanner.pos
        depth = 0

        until @scanner.eos?
          char = @scanner.peek(1)

          if char == "'" || char == '"'
            skip_string
            next
          end

          if char == '[' || char == '(' || char == '{'
            depth += 1
          elsif char == ']' || char == ')' || char == '}'
            break if depth.zero?

            depth -= 1
          elsif depth.zero? && char == ','
            break
          end

          @scanner.pos += 1
        end

        @scanner.string.byteslice(start, @scanner.pos - start)
      end

      def skip_string
        quote = @scanner.get_byte
        body = @scanner.scan_until(/(?=#{Regexp.escape(quote)})/)
        raise_syntax_error('unclosed_string') if body.nil?
        @scanner.get_byte # consume closing quote
      end

      def register_variable!(name)
        if @seen_variables.key?(name)
          raise_syntax_error('duplicate_variable', variable: name)
        end
        @seen_variables[name] = true
      end

      def skip_whitespace
        @scanner.skip(WHITESPACE)
      end

      def consume!(char, error_key = 'unexpected_token')
        skip_whitespace
        unless @scanner.peek(1) == char
          raise_syntax_error(error_key, token: char)
        end
        @scanner.get_byte
      end

      def expect_eos
        skip_whitespace
        raise_syntax_error('trailing_content') unless @scanner.eos?
      end

      def raise_syntax_error(key, **args)
        raise SyntaxError, @parse_context.locale.t("errors.syntax.with_#{key}", **args)
      end
    end
  end
end
