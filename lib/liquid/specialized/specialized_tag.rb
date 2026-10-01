# frozen_string_literal: true

module Liquid
  module Specialized
    # Tags copied from the parsed AST with their block bodies replaced by
    # specialized bodies. Copying (rather than mutating the frozen parsed
    # AST) keeps the original template reusable.
    module SpecializedTag
      class << self
        # Single-body block tags: for, capture, table_row, comment, ...
        def clone_block(tag)
          copy = tag.dup
          copy.extend(ClonedBlock) unless copy.is_a?(For)
          copy.extend(ClonedFor) if copy.is_a?(For)
          copy
        end

        # if/unless/case: conditions form a linear chain via child_condition
        # and only the head carries an attachment, so shallow-duping each
        # condition is enough to leave the parsed AST untouched.
        def clone_conditional(tag)
          copy = tag.dup
          blocks = tag.blocks.map(&:dup)
          copy.instance_variable_set(:@blocks, blocks)
          copy.extend(tag.is_a?(Case) ? ClonedCase : ClonedIf)
          copy
        end
      end
    end

    # A copied single-body Block that renders a specialized body.
    module ClonedBlock
      def replace_body(body)
        @body = body
      end

      def body_object
        @body
      end
    end

    # A copied If/Unless with specialized branch bodies.
    module ClonedIf
      def replace_branch_body(index, body)
        @blocks[index].attach(body)
      end
    end

    # A copied Case with specialized branch bodies.
    module ClonedCase
      def replace_branch_body(index, body)
        @blocks[index].attach(body)
      end
    end

    # A copied For with specialized loop/else bodies.
    module ClonedFor
      def replace_for_body(body)
        @for_block = body
      end

      def replace_else_body(body)
        @else_block = body
      end

      def for_body
        @for_block
      end

      def else_body
        @else_block
      end
    end
  end
end
