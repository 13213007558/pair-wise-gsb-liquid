# frozen_string_literal: true

module Liquid
  # A SafeString is a String whose contents are known to be safe for one of the
  # insertion contexts understood by Liquid's opt-in HTML auto-escaping mode
  # (see Liquid::HtmlAutoEscape).
  #
  # The +safe_category+ records *where* the content is trusted to be emitted:
  #
  # * +:html+      - safe as text content of an HTML element
  # * +:attribute+ - safe inside a single or double quoted HTML attribute value
  # * +:url+       - a sanitized value safe as a URL-typed attribute value
  #
  # Trust is monotonic for body output (attribute/url-safe strings are also
  # body-safe), but never flows "up" a context: an +:html+ string is not trusted
  # inside an attribute.
  #
  # SafeString always behaves as a regular String when auto-escaping is not
  # enabled, so the default rendering behaviour of Liquid is unchanged.
  #
  # Like Rails' html_safe strings (but with a context category), concatenating a
  # SafeString with an *untrusted* fragment never lets the safe fragment bless
  # the whole result: +SafeString#+ returns a plain (untrusted) String unless
  # every operand is itself a SafeString.
  class SafeString < String
    # Ordered from least to most contextual trust. Every category is trusted in
    # every context at or below its own level.
    CATEGORIES = [:html, :attribute, :url].freeze

    attr_reader :safe_category

    def initialize(str, category)
      raise ArgumentError, "unknown safe category #{category.inspect}" unless CATEGORIES.include?(category)

      super(str)
      @safe_category = category
      freeze
    end

    # Safe for a given target context if our category is at least as specific.
    def safe_for?(category)
      return false unless CATEGORIES.include?(category)

      CATEGORIES.index(@safe_category) >= CATEGORIES.index(category)
    end

    def html_safe?
      true
    end

    # A plain concatenation cannot gain trust from a single safe fragment.
    # "safe" + "user text" therefore produces an untrusted String unless the
    # other operand is trusted for the same context.
    def +(other)
      result = super
      if other.is_a?(SafeString) && other.safe_category == @safe_category
        SafeString.new(result, @safe_category)
      else
        result
      end
    end

    # Preserve the category for byte/character slice helpers such as String#[].
    def [](*args)
      result = super
      result.is_a?(String) ? SafeString.new(result, @safe_category) : result
    end

    # A copy without a trust category, used when a filter might have introduced
    # untrusted content.
    def to_unsafe_string
      String.new(self)
    end
  end
end
