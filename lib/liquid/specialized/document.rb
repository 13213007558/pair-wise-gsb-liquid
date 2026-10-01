# frozen_string_literal: true

module Liquid
  module Specialized
    # A Liquid::Document whose body is the result of a specialization pass.
    class Document < Liquid::Document
      def initialize(parse_context, body)
        @parse_context = parse_context
        @body = body
      end
    end
  end
end