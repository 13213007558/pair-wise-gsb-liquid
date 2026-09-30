# frozen_string_literal: true

module Liquid
  class ParseContext
    attr_accessor :locale, :line_number, :trim_whitespace, :depth
    attr_reader :partial, :warnings, :error_mode, :environment

    def initialize(options = Const::EMPTY_HASH)
      @environment = options.fetch(:environment, Environment.default)
      @template_options = options ? options.dup : {}

      @locale   = @template_options[:locale] ||= I18n.new
      @warnings = []

      # constructing new StringScanner in Lexer, Tokenizer, etc is expensive
      # This StringScanner will be shared by all of them
      @string_scanner = StringScanner.new("")

      @expression_cache = if options[:expression_cache].nil?
        {}
      elsif options[:expression_cache].respond_to?(:[]) && options[:expression_cache].respond_to?(:[]=)
        options[:expression_cache]
      elsif options[:expression_cache]
        {}
      end

      # Lexically scoped stack of labels declared by enclosing `for` loops.
      # Used at parse time to resolve {% break label %} / {% continue label %}.
      @for_label_stack        = []
      @saved_for_label_stacks = []

      self.depth   = 0
      self.partial = false
    end

    # Called by the `for` tag when it starts parsing its body. Labels are
    # lexically scoped: re-declaring a label that is already used by an
    # enclosing `for` loop (shadowing) is a syntax error.
    def push_for_label(label)
      if @for_label_stack.include?(label)
        raise SyntaxError, locale.t("errors.syntax.for_label_duplicate", label: label)
      end
      @for_label_stack.push(label)
    end

    def pop_for_label
      @for_label_stack.pop
    end

    # Is `label` declared by a `for` loop currently being parsed?
    def for_label?(label)
      @for_label_stack.include?(label)
    end

    def [](option_key)
      @options[option_key]
    end

    def new_block_body
      Liquid::BlockBody.new
    end

    def new_parser(input)
      @string_scanner.string = input
      Parser.new(@string_scanner, reject_bare_brackets: @error_mode == :strict2 || @error_mode == :rigid)
    end

    def new_tokenizer(source, start_line_number: nil, for_liquid_tag: false)
      Tokenizer.new(
        source: source,
        string_scanner: @string_scanner,
        line_number: start_line_number,
        for_liquid_tag: for_liquid_tag,
      )
    end

    def safe_parse_expression(parser)
      Expression.safe_parse(parser, @string_scanner, @expression_cache)
    end

    def parse_expression(markup, safe: false)
      if !safe && @error_mode == :strict2
        # parse_expression is a widely used API. To maintain backward
        # compatibility while raising awareness about strict2 parser standards,
        # the safe flag supports API users make a deliberate decision.
        #
        # In strict2 mode, markup MUST come from a string returned by the parser
        # (e.g., parser.expression). We're not calling the parser here to
        # prevent redundant parser overhead.
        raise Liquid::InternalError, "unsafe parse_expression cannot be used in strict2 mode"
      end

      Expression.parse(markup, @string_scanner, @expression_cache)
    end

    def partial=(value)
      @partial = value
      @options = value ? partial_options : @template_options

      @error_mode = @options[:error_mode] || @environment.error_mode

      # Loop labels are lexically scoped to a single template fragment: a
      # {% break %}/{% continue %} inside a rendered partial must not be able
      # to target a `for` loop of the including template.
      if value
        @saved_for_label_stacks.push(@for_label_stack)
        @for_label_stack = []
      else
        @for_label_stack = @saved_for_label_stacks.pop || []
      end
    end

    def partial_options
      @partial_options ||= begin
        dont_pass = @template_options[:include_options_blacklist]
        if dont_pass == true
          { locale: locale }
        elsif dont_pass.is_a?(Array)
          @template_options.reject { |k, _v| dont_pass.include?(k) }
        else
          @template_options
        end
      end
    end
  end
end
