# frozen_string_literal: true

module Liquid
  # @liquid_public_docs
  # @liquid_type tag
  # @liquid_category variable
  # @liquid_name destructure
  # @liquid_summary
  #   Binds local variables by destructuring an array or object for the duration of a block.
  # @liquid_description
  #   The `destructure` tag matches a pattern against an expression and binds the
  #   matched parts to local variables. The bindings are only visible inside the
  #   block; when the block ends, any outer variables with the same name are
  #   restored.
  #
  #   Patterns can be nested and support array items, object keys, rest items,
  #   and default expressions for missing items. An explicit `nil` value is not
  #   the same as a missing item: defaults only apply when an array position is
  #   absent or an object key does not exist.
  #
  #   If any part of the pattern fails to match (a required item is missing and
  #   has no default, or an array/object pattern is matched against a value of
  #   the wrong type), none of the bindings take effect and the block body is
  #   rendered with the outer scope only.
  #
  # @liquid_syntax
  #   {% destructure [user, *permissions] = payload %}
  #     {{ user.name }}
  #   {% enddestructure %}
  # @liquid_syntax_keyword pattern An array pattern `[a, b]`, an object pattern `{name, email: mail}`, or a variable name.
  # @liquid_syntax_keyword expression The value to destructure.
  class Destructure < Block
    IDENTIFIER = /[a-zA-Z_][a-zA-Z0-9_-]*/

    # Sentinel for "no value exists at this position" (an absent array index or
    # object key). An explicit nil is a real value and never triggers a default.
    MISSING = Object.new.freeze

    # Sentinel for "this pattern has no default expression".
    NO_DEFAULT = Object.new.freeze

    VariablePattern = Struct.new(:name, :default)
    ArrayPattern    = Struct.new(:elements, :rest, :default)
    ObjectPattern   = Struct.new(:entries, :rest, :default)

    # Recursive descent parser for destructure patterns.
    #
    #   pattern        := array_pattern | object_pattern | identifier
    #   array_pattern  := "[" [element ["," element]*] "]"
    #   element        := pattern ["=" default] | "*" identifier
    #   object_pattern := "{" [entry ["," entry]*] "}"
    #   entry          := key [":" pattern] ["=" default] | "**" identifier
    #   key            := identifier | quoted_string
    #
    # A rest item ("*" in arrays, "**" in objects) is only allowed as the very
    # last item of its pattern. Binding the same variable name twice is a
    # syntax error. Both are rejected here, at parse time.
    class PatternParser
      def initialize(markup, parse_context)
        @source        = markup.strip
        @ss            = StringScanner.new(@source)
        @parse_context = parse_context
        @names         = {}
      end

      def parse
        pattern = parse_pattern
        @ss.skip(/\s*/)
        error!("unexpected characters after the pattern") unless @ss.eos?
        pattern
      end

      private

      def parse_pattern
        @ss.skip(/\s*/)
        pattern =
          if @ss.scan(/\[/)
            parse_array_pattern
          elsif @ss.scan(/\{/)
            parse_object_pattern
          elsif (name = @ss.scan(IDENTIFIER))
            register_variable(name)
            VariablePattern.new(name)
          else
            error!("expected a variable name, '[' or '{'")
          end
        pattern.default = parse_default
        pattern
      end

      def parse_array_pattern
        elements = []
        rest     = nil

        loop do
          @ss.skip(/\s*/)
          break if @ss.scan(/\]/)

          if @ss.scan(/\*/)
            rest = parse_rest_variable
            @ss.skip(/\s*/)
            rest_error!("*#{rest}") unless @ss.scan(/\]/)
            break
          end

          elements << parse_pattern
          @ss.skip(/\s*/)
          if @ss.scan(/,/)
            next
          elsif @ss.scan(/\]/)
            break
          else
            error!("expected ',' or ']'")
          end
        end

        ArrayPattern.new(elements, rest)
      end

      def parse_object_pattern
        entries = []
        rest    = nil

        loop do
          @ss.skip(/\s*/)
          break if @ss.scan(/\}/)

          if @ss.scan(/\*\*/)
            rest = parse_rest_variable
            @ss.skip(/\s*/)
            rest_error!("**#{rest}") unless @ss.scan(/\}/)
            break
          end

          key = parse_key
          @ss.skip(/\s*/)
          pattern =
            if @ss.scan(/:/)
              parse_pattern
            else
              unless key.match?(/\A#{IDENTIFIER}\z/o)
                error!("object key #{key.inspect} is not a valid variable name; use \"#{key}: variable\" to bind it")
              end
              register_variable(key)
              shorthand = VariablePattern.new(key)
              shorthand.default = parse_default
              shorthand
            end
          entries << [key, pattern]

          @ss.skip(/\s*/)
          if @ss.scan(/,/)
            next
          elsif @ss.scan(/\}/)
            break
          else
            error!("expected ',' or '}'")
          end
        end

        ObjectPattern.new(entries, rest)
      end

      def parse_key
        @ss.skip(/\s*/)
        if (key = @ss.scan(IDENTIFIER))
          key
        elsif (quoted = @ss.scan(/"[^"]*"|'[^']*'/))
          quoted[1..-2]
        else
          error!("expected an object key")
        end
      end

      def parse_rest_variable
        @ss.skip(/\s*/)
        name = @ss.scan(IDENTIFIER)
        error!("expected a variable name after the rest marker") unless name
        register_variable(name)
        name
      end

      def parse_default
        @ss.skip(/\s*/)
        return NO_DEFAULT unless @ss.scan(/=/)

        @ss.skip(/\s*/)
        markup = scan_expression
        error!("expected an expression after '='") if markup.empty?

        parser     = @parse_context.new_parser(markup)
        expression = @parse_context.safe_parse_expression(parser)
        parser.consume(:end_of_string)
        expression
      end

      # Consumes a default expression, stopping at the first top-level
      # ',', ']' or '}' (the delimiters of the enclosing pattern). Quoted
      # strings and nested brackets inside the expression are respected.
      def scan_expression
        start = @ss.pos
        depth = 0
        quote = nil

        while (char = @ss.getch)
          if quote
            quote = nil if char == quote
            next
          end

          case char
          when '"', "'"
            quote = char
          when '(', '[', '{'
            depth += 1
          when ')', ']', '}'
            if depth.zero?
              @ss.pos -= 1
              break
            end
            depth -= 1
          when ','
            if depth.zero?
              @ss.pos -= 1
              break
            end
          end
        end

        @ss.string[start...@ss.pos].strip
      end

      def register_variable(name)
        if @names.key?(name)
          raise SyntaxError, @parse_context.locale.t(
            "errors.syntax.destructure_duplicate_variable",
            variable: name,
            pattern: @source,
          )
        end
        @names[name] = true
      end

      def error!(reason)
        raise SyntaxError, @parse_context.locale.t(
          "errors.syntax.destructure_pattern",
          reason: reason,
          pattern: @source,
        )
      end

      def rest_error!(rest)
        raise SyntaxError, @parse_context.locale.t(
          "errors.syntax.destructure_invalid_rest",
          rest: rest,
          pattern: @source,
        )
      end
    end

    attr_reader :pattern, :expression

    def initialize(tag_name, markup, parse_context)
      super
      pattern_markup, expression_markup = split_pattern_and_expression(markup)

      if pattern_markup.nil? || pattern_markup.strip.empty? || expression_markup.strip.empty?
        raise SyntaxError, parse_context.locale.t("errors.syntax.destructure")
      end

      @pattern = PatternParser.new(pattern_markup, parse_context).parse

      parser = parse_context.new_parser(expression_markup.strip)
      @expression = parse_context.safe_parse_expression(parser)
      parser.consume(:end_of_string)
    end

    def render_to_output_buffer(context, output)
      value    = context.evaluate(@expression)
      bindings = {}
      matched  = match_pattern(@pattern, value, context, bindings)

      # The bindings are scoped to the block: context.stack restores any
      # outer variables with the same name when the block exits. On a match
      # failure none of the bindings take effect.
      context.stack(matched ? bindings : {}) do
        @body.render_to_output_buffer(context, output)
      end

      output
    end

    private

    # Splits "pattern = expression" at the first top-level '='. Defaults use
    # '=' as well, but they always appear inside brackets or braces, so a
    # depth-zero '=' unambiguously separates the pattern from the expression.
    def split_pattern_and_expression(markup)
      depth = 0
      quote = nil

      markup.each_char.with_index do |char, index|
        if quote
          quote = nil if char == quote
          next
        end

        case char
        when '"', "'"
          quote = char
        when '[', '{', '('
          depth += 1
        when ']', '}', ')'
          depth -= 1
        when '='
          return [markup[0...index], markup[(index + 1)..]] if depth.zero?
        end
      end

      nil
    end

    # Matches a pattern against a value, filling +bindings+. Returns false if
    # the match fails; in that case the partially filled bindings are
    # discarded by the caller, so a failed match never takes effect.
    def match_pattern(pattern, value, context, bindings)
      if value.equal?(MISSING)
        default = pattern.default
        return false if default.equal?(NO_DEFAULT)

        value = context.evaluate(default)
      end

      case pattern
      when VariablePattern
        bindings[pattern.name] = value
        true
      when ArrayPattern
        match_array_pattern(pattern, value, context, bindings)
      when ObjectPattern
        match_object_pattern(pattern, value, context, bindings)
      end
    end

    def match_array_pattern(pattern, value, context, bindings)
      return false unless value.is_a?(Array)

      elements = pattern.elements
      size     = value.size

      elements.each_with_index do |element, index|
        item = index < size ? value[index] : MISSING
        return false unless match_pattern(element, item, context, bindings)
      end

      if (rest = pattern.rest)
        bindings[rest] = value[elements.size..] || []
      end

      true
    end

    def match_object_pattern(pattern, value, context, bindings)
      return false unless value.is_a?(Hash) || value.is_a?(Drop)

      rest          = pattern.rest
      matched_keys  = rest ? [] : nil
      missing_check = value.is_a?(Hash)

      pattern.entries.each do |key, subpattern|
        item =
          if missing_check
            # Hash#key? distinguishes a missing key from an explicit nil.
            value.key?(key) ? context.lookup_and_evaluate(value, key, raise_on_not_found: false) : MISSING
          else
            # Drops cannot distinguish the two; nil is treated as missing.
            item = context.lookup_and_evaluate(value, key, raise_on_not_found: false)
            item.nil? ? MISSING : item
          end
        return false unless match_pattern(subpattern, item, context, bindings)

        matched_keys&.push(key)
      end

      if rest
        return false unless value.respond_to?(:each_key)

        remaining = {}
        value.each_key do |key|
          next if matched_keys.include?(key)

          remaining[key] = context.lookup_and_evaluate(value, key, raise_on_not_found: false)
        end
        bindings[rest] = remaining
      end

      true
    end

    class ParseTreeVisitor < Liquid::ParseTreeVisitor
      def children
        super + [@node.expression]
      end
    end
  end
end
