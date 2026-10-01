# frozen_string_literal: true

module Liquid
  # @liquid_public_docs
  # @liquid_type object
  # @liquid_name forloop
  # @liquid_summary
  #   Information about a parent [`for` loop](/docs/api/liquid/tags/for).
  class ForloopDrop < Drop
    def initialize(name, length, parentloop)
      @name       = name
      @length     = length
      @parentloop = parentloop
      @index      = 0
    end

    # @liquid_public_docs
    # @liquid_name length
    # @liquid_summary
    #   The total number of iterations in the loop.
    # @liquid_return [number]
    attr_reader :length

    # @liquid_public_docs
    # @liquid_name parentloop
    # @liquid_summary
    #   The parent `forloop` object.
    # @liquid_description
    #   If the current `for` loop isn't nested inside another `for` loop, then `nil` is returned.
    # @liquid_return [forloop]
    attr_reader :parentloop

    attr_reader :name

    # @liquid_public_docs
    # @liquid_summary
    #   The 1-based index of the current iteration.
    # @liquid_return [number]
    def index
      @index + 1
    end

    # @liquid_public_docs
    # @liquid_summary
    #   The 0-based index of the current iteration.
    # @liquid_return [number]
    def index0
      @index
    end

    # @liquid_public_docs
    # @liquid_summary
    #   The 1-based index of the current iteration, in reverse order.
    # @liquid_return [number]
    def rindex
      @length - @index
    end

    # @liquid_public_docs
    # @liquid_summary
    #   The 0-based index of the current iteration, in reverse order.
    # @liquid_return [number]
    def rindex0
      @length - @index - 1
    end

    # @liquid_public_docs
    # @liquid_summary
    #   Returns `true` if the current iteration is the first. Returns `false` if not.
    # @liquid_return [boolean]
    def first
      @index == 0
    end

    # @liquid_public_docs
    # @liquid_summary
    #   Returns `true` if the current iteration is the last. Returns `false` if not.
    # @liquid_return [boolean]
    def last
      @index == @length - 1
    end

    protected

    def increment!
      @index += 1
    end
  end

  # A ForloopDrop used by streaming `for` loops (`{% for item in collection stream %}`),
  # where the collection is consumed lazily and its total length is unknown.
  #
  # `index`, `index0`, and `first` behave as usual, and `last` is answered through
  # a one-item lookahead. Attributes that require the total length of the
  # collection (`length`, `rindex`, and `rindex0`) return `nil` to signal that
  # the value is unavailable.
  class StreamingForloopDrop < ForloopDrop
    def initialize(name, parentloop)
      super(name, nil, parentloop)
      @last = false
    end

    def rindex
      nil
    end

    def rindex0
      nil
    end

    def last
      @last
    end

    protected

    attr_writer :last
  end
end
