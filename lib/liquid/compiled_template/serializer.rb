# frozen_string_literal: true

require 'json'
require 'set'

module Liquid
  module CompiledTemplate
    class Serializer
      def serialize(template, partials: nil)
        @provided_partials = partials || {}
        @serialized_partials = {}
        @filters = Set.new
        @custom_tags = Set.new
        @references = {}
        @partial_queue = []
        @queued_partials = Set.new

        @root_name = root_name = template.name || 'compiled_template'
        root = serialize_template(template, root_name, false)
        drain_partial_queue(template.environment)

        package = {
          'format' => CompiledTemplate::FORMAT,
          'version' => CompiledTemplate::VERSION,
          'name' => root_name,
          'template' => root,
          'partials' => @serialized_partials,
          'filters' => @filters.to_a.sort,
          'tags' => @custom_tags.to_a.sort,
        }
        JSON.parse(JSON.generate(package))
      rescue JSON::GeneratorError, TypeError => e
        raise CompiledTemplateError, "compiled template contains non-JSON data: #{e.message}"
      end

      def expression(value)
        case value
        when nil then { 't' => 'nil' }
        when true, false, Integer, String then value
        when Float
          raise CompiledTemplateError, "unsupported Float #{value.inspect}" unless value.finite?
          value
        when VariableLookup then lookup(value)
        when RangeLookup then { 't' => 'range', 'start' => expression(value.start_obj), 'end' => expression(value.end_obj) }
        when Range
          unless value.begin.is_a?(Integer) && value.end.is_a?(Integer) && !value.exclude_end?
            raise CompiledTemplateError, "unsupported range #{value.inspect}"
          end
          { 't' => 'range_literal', 'start' => value.begin, 'end' => value.end }
        when Condition::MethodLiteral
          unless Condition.instance_variable_get(:@@method_literals).value?(value)
            raise CompiledTemplateError, "unsupported method literal #{value.method_name.inspect}"
          end
          { 't' => 'method', 'name' => value.method_name.to_s }
        when Symbol
          raise CompiledTemplateError, "unsupported symbol #{value.inspect}" unless value == :continue
          { 't' => 'symbol', 'name' => 'continue' }
        else
          raise CompiledTemplateError, "unsupported expression #{value.class}"
        end
      end

      def body(block_body)
        { 't' => 'body', 'blank' => block_body.blank?, 'nodes' => block_body.nodelist.map { |node| node(node) } }
      end

      private

      def drain_partial_queue(environment)
        while (name = @partial_queue.shift)
          next if @serialized_partials.key?(name) || name == @root_name
          raise CompiledTemplateError, "too many compiled partials" if @serialized_partials.size >= CompiledTemplate::MAX_PARTIALS

          template = resolve_partial(name, environment)
          @serialized_partials[name] = serialize_template(template, name, true)
        end
      end

      def resolve_partial(name, environment)
        value = @provided_partials[name]
        return value if value.is_a?(Template)

        source = value || environment.file_system.read_template_file(name)
        unless source.is_a?(String)
          raise CompiledTemplateError, "partial #{name.inspect} must be a Liquid::Template or String"
        end

        Template.parse(
          source,
          environment: environment,
          line_numbers: true,
          error_mode: environment.error_mode,
        )
      end

      def serialize_template(template, name, partial)
        unless template.root.is_a?(Document)
          raise CompiledTemplateError, "template #{name.inspect} has not been parsed"
        end

        @current_references = { 'render' => Set.new, 'include' => Set.new }
        data = {
          'name' => name,
          'partial' => partial,
          'error_mode' => template.instance_variable_get(:@error_mode).to_s,
          'root' => node(template.root),
        }
        @references[name] = @current_references
        data['references'] = {
          'render' => @current_references['render'].to_a.sort,
          'include' => @current_references['include'].to_a.sort,
        }
        data
      ensure
        @current_references = nil
      end

      def node(value)
        case value
        when String then value
        when Document then { 't' => 'document', 'body' => body(value.body) }
        when BlockBody then body(value)
        when Variable then variable(value)
        when If, Unless then conditional_block(value)
        when Case then case_node(value)
        when For then for_node(value)
        when TableRow then table_row_node(value)
        when Capture then simple_block(value, 'capture', 'to' => value.to)
        when Ifchanged then simple_block(value, 'ifchanged')
        when Comment then { 't' => 'comment', 'line' => value.line_number, 'blank' => value.blank? }
        when Raw then { 't' => 'raw', 'body' => value.instance_variable_get(:@body), 'line' => value.line_number, 'blank' => value.blank? }
        when Doc then { 't' => 'doc', 'line' => value.line_number, 'blank' => value.blank?, 'body' => value.instance_variable_get(:@body) }
        when Assign then { 't' => 'assign', 'to' => value.to, 'value' => variable(value.from), 'line' => value.line_number, 'blank' => value.blank? }
        when Echo then { 't' => 'echo', 'value' => variable(value.variable), 'line' => value.line_number, 'blank' => value.blank? }
        when Increment then simple_tag(value, 'increment', 'variable' => value.variable_name)
        when Decrement then simple_tag(value, 'decrement', 'variable' => value.variable_name)
        when Cycle then cycle_node(value)
        when Break then simple_tag(value, 'break')
        when Continue then simple_tag(value, 'continue')
        when InlineComment then simple_tag(value, '#')
        when Render then partial_tag(value, 'render')
        when Include then partial_tag(value, 'include')
        when Tag then custom_tag(value)
        else raise CompiledTemplateError, "unsupported node #{value.class}"
        end
      end

      def variable(value)
        value.filters.each { |filter_name, *_| @filters << filter_name }
        {
          't' => 'variable',
          'name' => expression(value.name),
          'filters' => value.filters.map { |filter| filter(filter) },
          'line' => value.line_number,
        }
      end

      def filter(value)
        name, args = value
        kwargs = value[2] || {}
        result = [name, args.map { |argument| expression(argument) }]
        result << kwargs.transform_values { |argument| expression(argument) } unless kwargs.empty?
        result
      end

      def lookup(value)
        command_flags = 0
        value.lookups.each_index do |index|
          command_flags |= 1 << index if value.send(:lookup_command?, index)
        end

        {
          't' => 'lookup',
          'name' => expression(value.name),
          'lookups' => value.lookups.map { |item| expression(item) },
          'command_flags' => command_flags,
        }
      end

      def conditional_block(value)
        type = value.is_a?(Unless) ? 'unless' : 'if'
        {
          't' => type,
          'line' => value.line_number,
          'blank' => value.blank?,
          'blocks' => value.blocks.map do |block|
            { 'condition' => condition_data(block), 'body' => body(block.attachment) }
          end,
        }
      end

      def condition_data(value)
        data = {
          'left' => expression(value.left),
          'operator' => value.operator,
          'right' => value.right.nil? ? nil : expression(value.right),
        }
        if value.child_condition
          data['relation'] = value.send(:child_relation).to_s
          data['child'] = condition_data(value.child_condition)
        end
        data['else'] = true if value.is_a?(ElseCondition)
        data
      end

      def case_node(value)
        groups = {}
        value.blocks.each do |block|
          group = groups[block.attachment.object_id] ||= {
            'body' => body(block.attachment),
            'conditions' => [],
          }
          group['conditions'] << condition_data(block)
        end

        {
          't' => 'case',
          'line' => value.line_number,
          'blank' => value.blank?,
          'left' => expression(value.left),
          'blocks' => groups.values,
        }
      end

      def for_node(value)
        {
          't' => 'for',
          'line' => value.line_number,
          'blank' => value.blank?,
          'variable' => value.variable_name,
          'collection' => expression(value.collection_name),
          'name' => value.instance_variable_get(:@name),
          'reversed' => !!value.instance_variable_get(:@reversed),
          'limit' => expression(value.limit),
          'from' => expression(value.from),
          'body' => body(value.instance_variable_get(:@for_block)),
          'else_body' => (body(value.instance_variable_get(:@else_block)) if value.instance_variable_get(:@else_block)),
        }
      end

      def table_row_node(value)
        {
          't' => 'tablerow',
          'line' => value.line_number,
          'blank' => value.blank?,
          'variable' => value.variable_name,
          'collection' => expression(value.collection_name),
          'attributes' => value.attributes.transform_values { |argument| expression(argument) },
          'body' => body(value.instance_variable_get(:@body)),
        }
      end

      def simple_block(value, type, attributes = nil)
        data = { 't' => type, 'line' => value.line_number, 'blank' => value.blank?, 'body' => body(value.instance_variable_get(:@body)) }
        attributes&.each { |key, attribute| data[key] = attribute }
        data
      end

      def simple_tag(value, type, attributes = nil)
        data = { 't' => type, 'line' => value.line_number, 'blank' => value.blank? }
        attributes&.each { |key, attribute| data[key] = attribute }
        data
      end

      def cycle_node(value)
        {
          't' => 'cycle',
          'line' => value.line_number,
          'blank' => value.blank?,
          'name' => expression(value.instance_variable_get(:@name)),
          'named' => value.named?,
          'variables' => value.variables.map { |variable| expression(variable) },
        }
      end

      def partial_tag(value, type)
        reference(value.template_name_expr, type)
        data = {
          't' => type,
          'line' => value.line_number,
          'blank' => value.blank?,
          'template' => expression(value.template_name_expr),
          'variable' => expression(value.variable_name_expr),
          'for' => value.for_loop?,
          'alias' => value.instance_variable_get(:@alias_name),
          'attributes' => value.attributes.transform_values { |argument| expression(argument) },
        }
        data
      end

      def reference(expression_value, type)
        return unless expression_value.is_a?(String)
        return unless @current_references

        @current_references[type] << expression_value
        @partial_queue << expression_value if @queued_partials.add?(expression_value)
      end

      def custom_tag(value)
        standard_class = Tags::STANDARD_TAGS[value.tag_name]
        if standard_class && value.class == standard_class
          raise CompiledTemplateError, "unserialized standard tag #{value.tag_name.inspect}"
        end

        @custom_tags << value.tag_name
        if value.respond_to?(:to_liquid_compiled)
          data = value.to_liquid_compiled
          unless data.is_a?(Hash) && data['t'] == 'custom'
            raise CompiledTemplateError, "custom tag #{value.tag_name.inspect} returned invalid compiled data"
          end
          return data.merge('tag' => value.tag_name, 'line' => value.line_number)
        end

        data = {
          't' => 'custom_tag',
          'tag' => value.tag_name,
          'markup' => value.instance_variable_get(:@markup).to_s,
          'line' => value.line_number,
          'blank' => value.blank?,
        }
        if value.is_a?(Block) && value.instance_variable_defined?(:@body)
          data['body'] = body(value.instance_variable_get(:@body))
        end
        data
      end
    end
  end
end
