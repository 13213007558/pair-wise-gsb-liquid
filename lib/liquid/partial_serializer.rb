# frozen_string_literal: true

module Liquid
  # Serializes parsed Liquid expression nodes back into Liquid markup. Used by
  # the partial evaluator when rebuilding tags that must remain in the residual
  # template (for example a partially foldable filter chain or a kept
  # conditional).
  #
  # @api private
  module PartialSerializer
    module_function

    def expression(node)
      case node
      when nil
        "nil"
      when true
        "true"
      when false
        "false"
      when Integer, Float
        Liquid::Utils.to_s(node)
      when String
        string_literal(node)
      when VariableLookup
        lookup(node)
      when RangeLookup
        "(#{expression(node.start_obj)}..#{expression(node.end_obj)})"
      when ::Range
        "(#{expression(node.begin)}..#{expression(node.end)})"
      else
        raise PartialEvaluationError, "cannot serialize #{node.inspect}"
      end
    end

    def lookup(node)
      name = node.name
      markup = name.is_a?(::String) ? name : "[#{expression(name)}]"

      node.lookups.each do |lookup|
        if lookup.is_a?(::String) && lookup.match?(/\A#{VariableSegment}+\z/o)
          markup = "#{markup}.#{lookup}"
        else
          markup = "#{markup}[#{expression(lookup)}]"
        end
      end
      markup
    end

    def variable(variable_node)
      markup = expression(variable_node.name)
      variable_node.filters.each do |filter_name, args, kwargs|
        markup = "#{markup} | #{filter_name}"
        arg_list = serialized_filter_args(args, kwargs)
        markup = "#{markup}: #{arg_list}" if arg_list
      end
      markup
    end

    def serialized_filter_args(args, kwargs)
      positional = Array(args).map { |arg| expression(arg) }
      if kwargs
        kwargs.each do |key, value|
          positional << "#{key}: #{expression(value)}"
        end
      end
      return nil if positional.empty?

      positional.join(", ")
    end

    def condition(condition)
      markup = comparison(condition)

      current = condition
      while (child = current.instance_variable_get(:@child_condition))
        markup = "(#{markup}) #{current.instance_variable_get(:@child_relation)} #{comparison(child)}"
        current = child
      end

      markup
    end

    def comparison(node)
      operand(node.left)
      return operand(node.left) unless node.operator

      "#{operand(node.left)} #{node.operator} #{operand(node.right)}"
    end

    def operand(node)
      node.is_a?(Condition::MethodLiteral) ? node.to_s : expression(node)
    end

    def string_literal(string)
      if string.include?('"') && !string.include?("'")
        "'#{string}'"
      else
        "\"#{string.gsub('"', '\\"')}\""
      end
    end

    # Rebuilds the source of a fully retained node (a tag that the partial
    # evaluator is not allowed to execute). Block bodies are rebuilt
    # recursively so that constant folding inside them is preserved.
    def node(node, bodies = nil)
      case node
      when ::String
        node
      when Variable
        "{{ #{variable(node)} }}"
      when Raw
        "{% raw %}#{node.instance_variable_get(:@body)}{% endraw %}"
      when Echo
        "{% echo #{variable(node.variable)} %}"
      when Assign
        "{% assign #{node.to} = #{variable(node.from)} %}"
      when Increment
        "{% increment #{node.variable_name} %}"
      when Decrement
        "{% decrement #{node.variable_name} %}"
      when Cycle
        cycle(node)
      when If, Unless
        conditional(node, bodies)
      when Case
        case_tag(node, bodies)
      when For
        for_tag(node, bodies)
      when Block
        generic_block(node, bodies)
      when Tag
        generic_tag(node)
      else
        raise PartialEvaluationError, "cannot serialize node #{node.class}"
      end
    end

    def cycle(node)
      name = node.named? ? "#{expression(node.instance_variable_get(:@name))}: " : ""
      variables = node.variables.map { |var| expression(var) }.join(", ")
      "{% cycle #{name}#{variables} %}"
    end

    def conditional(node, bodies)
      keyword = node.is_a?(Unless) ? "unless" : "if"
      source = +"{% #{keyword} #{comparison(node.blocks.first)} %}"
      source << body_source(node.blocks.first, bodies)

      node.blocks[1..].each do |block|
        if block.is_a?(ElseCondition)
          source << "{% else %}"
          source << body_source(block, bodies)
        else
          source << "{% elsif #{comparison(block)} %}"
          source << body_source(block, bodies)
        end
      end
      source << "{% end#{keyword} %}"
      source
    end

    def case_tag(node, bodies)
      source = +"{% case #{expression(node.left)} %}"
      node.blocks.each do |block|
        if block.is_a?(ElseCondition)
          source << "{% else %}"
        else
          source << "{% when #{expression(block.right)} %}"
        end
        source << body_source(block, bodies)
      end
      source << "{% endcase %}"
      source
    end

    def for_tag(node, bodies)
      markup = +"#{node.variable_name} in #{expression(node.collection_name)}"
      markup << " reversed" if node.instance_variable_get(:@reversed)
      if node.from && node.from != :continue && !node.from.nil?
        markup << ", offset: #{expression(node.from)}"
      elsif node.from == :continue
        markup << ", offset: continue"
      end
      markup << ", limit: #{expression(node.limit)}" if node.limit

      source = +"{% for #{markup} %}"
      source << body_for(node, bodies, :for_block)
      if node.else_block
        source << "{% else %}"
        source << body_for(node, bodies, :else_block)
      end
      source << "{% endfor %}"
      source
    end

    def generic_block(node, bodies)
      tag_name = node.tag_name
      delimiter = node.respond_to?(:block_delimiter, true) ? node.send(:block_delimiter) : "end#{tag_name}"
      body = bodies && bodies[node]
      source = +"{% #{tag_name} #{node.raw.delete_prefix(tag_name.to_s).strip} %}"
      source << (body ? body.join : node_source_nodelist(node.nodelist))
      source << "{% #{delimiter} %}"
      source
    end

    def generic_tag(node)
      "{% #{node.raw} %}"
    end

    def body_source(block, bodies)
      body = bodies && bodies[block.attachment]
      return body.join if body

      node_source_nodelist(block.attachment.nodelist)
    end

    def body_for(node, bodies, key)
      body = node.send(key)
      specialized = bodies && bodies[body]
      return specialized.join if specialized

      node_source_nodelist(body.nodelist)
    end

    def node_source_nodelist(nodelist)
      Array(nodelist).map do |child|
        child.is_a?(::String) ? child : node(child)
      end.join
    end

    # Renders a residual nodelist (which may contain {StaticOutput} nodes)
    # back into approximate Liquid source, suitable for debugging why
    # preprocessing did not collapse an expression. This is not re-parsed by
    # the engine; the residual template renders from its AST directly.
    def residual_nodelist(nodes)
      Array(nodes).map do |child|
        case child
        when ::String
          child
        when StaticOutput
          literal_source(child.value)
        else
          node(child)
        end
      end.join
    end

    def literal_source(value)
      case value
      when nil
        ""
      when Array
        value.map { |entry| literal_source(entry) }.join
      when ::Range
        "{{ #{expression(value)} }}"
      when String, Numeric, true, false
        "{{ #{expression(value)} }}"
      else
        ""
      end
    end
  end
end
