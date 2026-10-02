# frozen_string_literal: true

module Liquid
  # Registry of filters that are allowed to be evaluated during template
  # partial evaluation (preprocessing).
  #
  # Only filters explicitly registered here can be executed when a template is
  # specialized against a set of known variables. A filter is eligible for
  # preprocessing only if it is a pure function of its arguments: it must not
  # read render-time state (context, registers, the template object), perform
  # I/O, or have any other side effect.
  #
  # Drop method dispatch is never performed by the partial evaluator, so the
  # safety of a registered filter is only considered for plain values
  # (nil, true/false, numbers, strings, arrays and hashes).
  class PureFilterRegistry
    # A conservative, dependency-free subset of Liquid::StandardFilters that is
    # demonstrably pure with respect to plain values. Filters that rely on the
    # render context (e.g. +sum+/+map+ through InputIterator, or +date+ with a
    # +Time+ input) are intentionally excluded.
    DEFAULT_STANDARD_FILTERS = %w[
      size downcase upcase capitalize escape escape_once
      url_encode url_decode base64_encode base64_decode
      base64_url_safe_encode base64_url_safe_decode
      slice truncate truncatewords split squish strip lstrip rstrip
      strip_html strip_newlines join sort sort_natural where reject
      has find find_index uniq reverse compact
      replace replace_first replace_last remove remove_first remove_last
      append concat prepend newline_to_br
      first last abs plus minus times divided_by modulo
      round ceil floor at_least at_most default
    ].freeze

    def initialize(names: nil)
      @names = (names || DEFAULT_STANDARD_FILTERS).map(&:to_s).to_set
    end

    # Explicitly registers one or more filter names as safe to run at
    # preprocessing time.
    def register(*names)
      names.flatten.each { |name| @names.add(name.to_s) }
      self
    end

    # Removes one or more filter names from the set allowed at preprocessing
    # time. Useful to opt out of a default standard filter for a particular
    # environment.
    def unregister(*names)
      names.flatten.each { |name| @names.delete(name.to_s) }
      self
    end

    def allow?(name)
      @names.include?(name.to_s)
    end

    def to_a
      @names.to_a
    end
  end
end
