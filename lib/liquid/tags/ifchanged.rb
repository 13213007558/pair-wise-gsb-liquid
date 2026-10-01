# frozen_string_literal: true

module Liquid
  class Ifchanged < Block
    def render_to_output_buffer(context, output)
      if (tracker = context.provenance)
        block_output = +''
        spans = tracker.capture { super(context, block_output) }

        if block_output != context.registers[:ifchanged]
          context.registers[:ifchanged] = block_output
          start = output.bytesize
          output << block_output
          tracker.record(spans, start)
        end

        return output
      end

      block_output = +''
      super(context, block_output)

      if block_output != context.registers[:ifchanged]
        context.registers[:ifchanged] = block_output
        output << block_output
      end

      output
    end
  end
end
