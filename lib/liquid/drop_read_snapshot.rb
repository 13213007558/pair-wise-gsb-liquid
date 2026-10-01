# frozen_string_literal: true

module Liquid
  # Per-render memoization of {Drop} property reads.
  #
  # When enabled for a render, the first read of a logical drop path (a given
  # drop instance plus a method or key) evaluates the underlying drop method.
  # That result, including +nil+ and other "missing" results, is reused for
  # every subsequent read of the same path for the rest of the render. This
  # keeps a report consistent when the backend data backing a drop changes
  # while the template is being rendered.
  #
  # A fresh snapshot is created for every top-level render, while isolated
  # subcontexts created by nested +{% render %}+ tags share the snapshot of
  # the render that invoked them.
  #
  # Properties are memoized lazily, so keys that are never visited (for
  # example attributes only referenced in a branch that is not taken) are
  # never evaluated. Drop instances are keyed by identity, so dynamic indexes
  # are cached per concrete path and per concrete drop. The drops themselves
  # are never duplicated or frozen; any mutable state they keep internally
  # continues to be shared normally.
  #
  # @api private
  class DropReadSnapshot
    def initialize
      @results = {}
    end

    # Returns the cached result of reading +method_name+ from +drop+,
    # evaluating the given block exactly once, on the first read.
    def fetch(drop, method_name)
      methods = @results[drop] ||= {}
      return methods[method_name] if methods.key?(method_name)

      methods[method_name] = yield
    end
  end
end
