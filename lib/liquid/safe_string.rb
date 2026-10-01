# frozen_string_literal: true

module Liquid
  # A String that carries a safety category for HTML autoescaping.
  #
  # SafeString instances are produced by escaping filters (such as +escape+),
  # by the {% capture %} tag, and by the autoescape layer itself. They tell
  # the renderer that the content has already been escaped (or validated) for
  # a particular set of HTML contexts, so it must not be escaped again.
  #
  # Categories:
  #   :html - escaped for HTML text and quoted attribute contexts
  #   :url  - protocol-validated and escaped for URL attribute contexts
  #           (a superset of :html, since the value is also HTML-escaped)
  #
  # Plain String concatenation (String#+, #concat, interpolation into a plain
  # String, and so on) returns a plain String, so a safe fragment can never
  # lend its trust to a larger, untrusted string.
  class SafeString < String
    # Maps a safety category to the HTML contexts it is safe to emit in.
    SAFE_IN = {
      html: [:text, :attr].freeze,
      url: [:text, :attr, :url].freeze,
    }.freeze

    attr_reader :safety

    def initialize(string, safety)
      unless SAFE_IN.key?(safety)
        raise ArgumentError, "unknown safety category: #{safety.inspect}"
      end

      super(string)
      @safety = safety
    end

    # Returns true if this string can be emitted without escaping in the
    # given HTML context (:text, :attr, or :url).
    def safe_in?(html_context)
      SAFE_IN.fetch(@safety).include?(html_context)
    end
  end
end
