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

  # A ForloopDrop for loops that stream a collection of unknown length.
  # The total length is never known without draining the stream, so the
  # length-dependent methods raise instead of silently consuming it.
  # `last` is still available: the loop looks ahead at most one item.
  class StreamingForloopDrop < ForloopDrop
    def initialize(name, parentloop)
      super(name, nil, parentloop)
      @last = false
    end

    def length
      raise ArgumentError, "forloop.length is not supported when streaming a collection of unknown length"
    end

    def rindex
      raise ArgumentError, "forloop.rindex is not supported when streaming a collection of unknown length"
    end

    def rindex0
      raise ArgumentError, "forloop.rindex0 is not supported when streaming a collection of unknown length"
    end

    def last
      @last
    end

    protected

    def last=(is_last)
      @last = is_last
    end
  end
end
