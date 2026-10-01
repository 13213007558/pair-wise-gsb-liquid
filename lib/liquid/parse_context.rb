# frozen_string_literal: true

module Liquid
  class ParseContext
    attr_accessor :locale, :line_number, :trim_whitespace, :depth
    attr_writer :html_context_tracker
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

      self.depth   = 0
      self.partial = false
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

    # Whether HTML autoescaping is enabled for this parse, either through the
    # template options or the environment.
    def html_autoescape?
      return @html_autoescape if defined?(@html_autoescape)

      @html_autoescape = if @template_options.key?(:html_autoescape)
        @template_options[:html_autoescape]
      else
        @environment.html_autoescape
      end
    end

    # The tracker that follows the static HTML of the template so that each
    # {{ }} output can be escaped for the context it appears in. Returns nil
    # when HTML autoescaping is disabled.
    def html_context_tracker
      return nil unless html_autoescape?

      @html_context_tracker ||= HtmlContextTracker.new
    end

    # Returns the HTML context (:text, :attr, or :url) for a {{ }} output at
    # the current parse position, or nil when HTML autoescaping is disabled.
    # Raises a SyntaxError for positions where no safe escaping exists
    # (script/style content, event handler or style attributes, and unquoted
    # attribute values) instead of guessing an escaping strategy.
    def html_context_for_output
      tracker = html_context_tracker
      return nil unless tracker

      context = tracker.current_context
      if HtmlContextTracker::FORBIDDEN_CONTEXTS.include?(context)
        description = case context
        when :script then "a <script> element"
        when :style then "a <style> element"
        when :script_attr then "an event handler attribute"
        when :style_attr then "a style attribute"
        else "an unquoted attribute value or tag"
        end
        raise SyntaxError, "dynamic output is not allowed in #{description} when html_autoescape is enabled"
      end
      context
    end
  end
end
