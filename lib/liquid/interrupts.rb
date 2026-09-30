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
  # When the {% break %} tag names a loop label (ex: {% break outer %}), the
  # interrupt carries that label so that only the matching `for` loop consumes
  # it; intervening loops re-push it and unwind.
  class BreakInterrupt < Interrupt
    attr_reader :label

    def initialize(label = nil)
      @label = label
      super()
    end
  end

  # Interrupt that is thrown whenever a {% continue %} is called.
  #
  # Like BreakInterrupt, an optional loop label selects which enclosing `for`
  # loop advances to its next iteration.
  class ContinueInterrupt < Interrupt
    attr_reader :label

    def initialize(label = nil)
      @label = label
      super()
    end
  end
end
