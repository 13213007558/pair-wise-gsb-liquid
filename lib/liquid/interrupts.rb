# frozen_string_literal: true

module Liquid
  # An interrupt is any command that breaks processing of a block (ex: a for loop).
  class Interrupt
    attr_reader :message

    def initialize(message = nil)
      @message = message || "interrupt"
    end
  end

  # Interrupt that is thrown whenever a {% break %} is called.
  #
  # When the {% break %} tag names a loop label (ex: {% break outer %}),
  # the interrupt carries that label and is only handled by the enclosing
  # for loop that declared it. Other loops re-queue the interrupt so it
  # propagates outwards.
  class BreakInterrupt < Interrupt
    attr_reader :label

    def initialize(label = nil)
      @label = label
      super()
    end
  end

  # Interrupt that is thrown whenever a {% continue %} is called.
  #
  # Like BreakInterrupt, it may carry the label of the targeted for loop.
  class ContinueInterrupt < Interrupt
    attr_reader :label

    def initialize(label = nil)
      @label = label
      super()
    end
  end
end
