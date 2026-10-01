# frozen_string_literal: true

module Liquid
  # Context-aware HTML escaping used by the opt-in HTML autoescape mode.
  module HtmlEscape
    ESCAPE_PATTERN = /[&<>"']/
    ESCAPE_MAP = {
      "&" => "&amp;",
      "<" => "&lt;",
      ">" => "&gt;",
      '"' => "&quot;",
      "'" => "&#39;",
    }.freeze

    # URL schemes allowed in URL attribute contexts. Anything with a scheme
    # outside this list (javascript:, data:, vbscript:, ...) is rejected.
    # Scheme-relative, absolute-path, fragment, and relative URLs carry no
    # scheme and are allowed.
    SAFE_URL_SCHEMES = ["http", "https", "mailto", "tel"].freeze

    SCHEME_PATTERN = /\A([a-zA-Z][a-zA-Z0-9+.\-]*):/

    # Browsers ignore ASCII whitespace and control characters while parsing
    # a URL scheme ("java\tscript:" is still javascript:), so the scheme
    # check runs on a candidate with those characters removed.
    URL_IGNORED_CHARACTERS = /[\x00-\x20]+/

    module_function

    # Escapes a string for HTML text and quoted attribute contexts.
    def escape_html(string)
      string.gsub(ESCAPE_PATTERN, ESCAPE_MAP)
    end

    # Validates the URL scheme and escapes the URL for a quoted attribute.
    # Raises Liquid::UnsafeUrlError for dangerous schemes instead of trying
    # to guess a safe rendering.
    def escape_url(string)
      candidate = string.gsub(URL_IGNORED_CHARACTERS, "")
      if (match = SCHEME_PATTERN.match(candidate))
        scheme = match[1].downcase
        unless SAFE_URL_SCHEMES.include?(scheme)
          raise UnsafeUrlError, "unsafe URL scheme #{scheme.inspect} is not allowed in a URL attribute"
        end
      end
      escape_html(string)
    end

    # Escapes +value+ for the given HTML context (:text, :attr, or :url),
    # returning a SafeString. Values that are already safe for the context
    # are returned unchanged so already-escaped content is never
    # double-escaped.
    def escape_for(html_context, value)
      return value if value.is_a?(SafeString) && value.safe_in?(html_context)

      string = value.is_a?(String) ? value : Utils.to_s(value)
      case html_context
      when :url
        SafeString.new(escape_url(string), :url)
      else
        SafeString.new(escape_html(string), :html)
      end
    end
  end
end
