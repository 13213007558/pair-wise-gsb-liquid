# frozen_string_literal: true

require 'json'

module Liquid
  class CompiledTemplate
    VERSION = 1
    FORMAT = 'liquid-template'

    DEFAULT_LIMITS = {
      bytes: 16 * 1024 * 1024,
      templates: 200,
      nodes_per_template: 20_000,
      depth: Block::MAX_DEPTH,
      string_length: 100_000,
      name_length: 255,
      references_per_template: 500,
    }.freeze

    class Encoder
      def initialize(template, file_system:, partials:, include_dependencies:)
        @template = template
        @environment = template.instance_variable_get(:@environment)
        @file_system = file_system || (partials.nil? ? @environment.file_system : nil)
        @partials = partials || {}
        @include_dependencies = include_dependencies
        @sources = {}
        @templates = {}
        @stack = []
      end

      def export
        root_name = template_name(@template)
        encode_template(@template, root_name)
        {
          'format' => FORMAT,
          'version' => VERSION,
          'root' => root_name,
          'templates' => @templates,
        }
      end

      private

      def encode_template(template, name)
        return if @templates.key?(name)
        raise CompiledTemplateError, "circular render dependency #{name}" if @stack.include?(name)

        @stack.push(name)
        cycle_counter = [0]
        references = []
        root = encode_document(template.root, references, cycle_counter, name)
        references.uniq! { |reference| reference[:name] }
        references.each do |reference|
          if prepare_partial(name, reference[:name])
            encode_partial(reference[:name])
          end
        end

        @templates[name] = {
          'name' => name,
          'error_mode' => error_mode(template).to_s,
          'line_numbers' => template.instance_variable_get(:@line_numbers) == true,
          'references' => references.map { |reference| reference[:name] }.uniq,
          'root' => root,
        }
      ensure
        @stack.pop
      end

      def encode_partial(name)
        return if @templates.key?(name)

        template = parse_partial(name, @sources.fetch(name))
        encode_template(template, name)
      end

      def prepare_partial(parent, name)
        return true if @templates.key?(name) || @sources.key?(name)

        if @partials.key?(name)
          @sources[name] = @partials.fetch(name).to_s
        elsif @file_system
          @sources[name] = read_partial(name)
        else
          return false
        end
        true
      rescue Liquid::Error
        raise
      rescue => error
        raise CompiledTemplateError, "unable to read render dependency #{name.inspect} referenced by #{parent.inspect}: #{error.message}"
      end

      def read_partial(name)
        @file_system.read_template_file(name)
      rescue Liquid::Error
        raise
      rescue => error
        raise CompiledTemplateError, "unable to read render dependency #{name.inspect}: #{error.message}"
      end

      def parse_partial(name, source)
        options = @template.root.parse_context.template_options.dup
        options[:environment] = @environment
        Template.new(environment: @environment).tap do |template|
          template.name = name
          template.parse(source, options)
        end
      end

      def encode_document(document, references, cycle_counter, template_name)
        { 'type' => 'document', 'body' => encode_body(document.body, references, cycle_counter, template_name) }
      end

      def encode_body(body, references, cycle_counter, template_name)
        {
          'type' => 'body',
          'blank' => body.send(:blank?) == true,
          'nodes' => body.nodelist.map { |node| encode_node(node, references, cycle_counter, template_name) },
        }
      end

      def encode_node(node, references, cycle_counter, template_name)
        case node
        when String
          node
        when Variable
          encode_variable(node)
        when Tag
          registered_class = @environment.tag_for_name(node.tag_name)
          if registered_class && node.class != registered_class
            return encode_custom_tag(node, references, cycle_counter, template_name)
          end

          encode_standard_tag(node, references, cycle_counter, template_name).tap do |data|
            data['tag_name'] = node.tag_name
            data['markup'] = node.instance_variable_get(:@markup).to_s
          end
        end
      end

      def encode_standard_tag(node, references, cycle_counter, template_name)
        case node
        when Echo
          { 'type' => 'echo', 'line_number' => node.line_number, 'variable' => encode_variable(node.variable) }
        when Render
          register_reference(references, node, true)
          encode_partial_tag(node, 'render')
        when Include
          register_reference(references, node, @include_dependencies)
          encode_partial_tag(node, 'include')
        when If, Unless
          encode_if(node, references, cycle_counter, template_name)
        when Case
          encode_case(node, references, cycle_counter, template_name)
        when For
          encode_for(node, references, cycle_counter, template_name)
        when TableRow
          encode_table_row(node, references, cycle_counter, template_name)
        when Capture
          encode_block(node, references, cycle_counter, template_name, 'capture', 'to' => node.to)
        when Assign
          { 'type' => 'assign', 'line_number' => node.line_number, 'to' => node.to, 'from' => encode_variable(node.from) }
        when Increment, Decrement, Break, Continue
          { 'type' => type_name(node), 'line_number' => node.line_number,
            **(node.respond_to?(:variable_name) ? { 'variable_name' => node.variable_name } : {}) }
        when InlineComment
          { 'type' => 'inline_comment', 'line_number' => node.line_number, 'markup' => node.raw.sub(/\A#\s*/, '') }
        when Comment
          { 'type' => 'comment', 'line_number' => node.line_number }
        when Ifchanged
          encode_block(node, references, cycle_counter, template_name, 'ifchanged')
        when Raw, Doc
          encode_text_block(node, references, cycle_counter, template_name)
        when Cycle
          encode_cycle(node, cycle_counter, template_name)
        else
          encode_custom_tag(node, references, cycle_counter, template_name)
        end
      end

      def register_reference(references, tag, include)
        return unless include && tag.template_name_expr.is_a?(String)
        references << { name: tag.template_name_expr, kind: type_name(tag) }
      end

      def encode_if(tag, references, cycle_counter, template_name)
        {
          'type' => tag.is_a?(Unless) ? 'unless' : 'if',
          'line_number' => tag.line_number,
          'blocks' => tag.blocks.map do |condition|
            { 'condition' => encode_condition(condition), 'body' => encode_body(condition.attachment, references, cycle_counter, template_name) }
          end,
        }
      end

      def encode_case(tag, references, cycle_counter, template_name)
        {
          'type' => 'case',
          'line_number' => tag.line_number,
          'left' => encode_expression(tag.left),
          'blocks' => tag.blocks.map do |condition|
            { 'condition' => encode_condition(condition), 'body' => encode_body(condition.attachment, references, cycle_counter, template_name) }
          end,
        }
      end

      def encode_for(tag, references, cycle_counter, template_name)
        result = {
          'type' => 'for',
          'line_number' => tag.line_number,
          'variable_name' => tag.variable_name,
          'collection' => encode_expression(tag.collection_name),
          'collection_source' => tag.instance_variable_get(:@name)[(tag.variable_name.length + 1)..],
          'reversed' => tag.instance_variable_get(:@reversed) == true,
          'body' => encode_body(tag.instance_variable_get(:@for_block), references, cycle_counter, template_name),
        }
        else_body = tag.instance_variable_get(:@else_block)
        result['else_body'] = encode_body(else_body, references, cycle_counter, template_name) if else_body
        result['from'] = tag.from == :continue ? 'continue' : encode_expression(tag.from) if tag.from
        result['limit'] = encode_expression(tag.limit) if tag.limit
        result
      end

      def encode_table_row(tag, references, cycle_counter, template_name)
        {
          'type' => 'tablerow',
          'line_number' => tag.line_number,
          'variable_name' => tag.variable_name,
          'collection' => encode_expression(tag.collection_name),
          'attributes' => encode_expression_hash(tag.attributes),
          'body' => encode_body(tag.instance_variable_get(:@body), references, cycle_counter, template_name),
        }
      end

      def encode_block(tag, references, cycle_counter, template_name, type, extra = {})
        { 'type' => type, 'line_number' => tag.line_number }.merge(extra).merge(
          'body' => encode_body(tag.instance_variable_get(:@body), references, cycle_counter, template_name),
        )
      end

      def encode_text_block(tag, references, cycle_counter, template_name)
        result = { 'type' => type_name(tag), 'line_number' => tag.line_number }
        body = tag.instance_variable_get(:@body)
        result['raw_body'] = body.is_a?(String) ? body : ''
        result['blank'] = body.is_a?(String) ? body.empty? : true
        result
      end

      def encode_cycle(tag, cycle_counter, template_name)
        cycle_counter[0] += 1
        result = {
          'type' => 'cycle',
          'line_number' => tag.line_number,
          'variables' => tag.variables.map { |expression| encode_expression(expression) },
          'named' => tag.named?,
        }
        result['name'] = encode_expression(tag.instance_variable_get(:@name)) if tag.named?
        if tag.variables.any? { |expression| !expression.is_a?(Integer) && !expression.is_a?(Float) && !expression.is_a?(String) }
          cycle_counter[0] += 1
          result['stable_key'] = "#{template_name}:cycle-#{cycle_counter[0]}"
        end
        result
      end

      def encode_partial_tag(tag, type)
        {
          'type' => type,
          'line_number' => tag.line_number,
          'template' => encode_expression(tag.template_name_expr),
          'variable' => encode_expression(tag.variable_name_expr),
          'alias_name' => tag.instance_variable_get(:@alias_name),
          'for_loop' => tag.for_loop? == true,
          'attributes' => encode_expression_hash(tag.attributes),
        }
      end

      def encode_custom_tag(tag, references, cycle_counter, template_name)
        data = {
          'type' => 'tag',
          'tag_name' => tag.tag_name,
          'markup' => tag.instance_variable_get(:@markup).to_s,
          'line_number' => tag.line_number,
        }
        payload = tag.compiled_tag_payload
        data['payload'] = validate_primitive(payload, 'custom tag payload') unless payload.nil?
        body = tag.instance_variable_get(:@body) if tag.instance_variable_defined?(:@body)
        if body.is_a?(BlockBody)
          data['body'] = encode_body(body, references, cycle_counter, template_name)
        elsif body.is_a?(String)
          data['raw_body'] = body
        end
        data
      end

      def encode_condition(condition)
        result = {
          'type' => condition.is_a?(ElseCondition) ? 'else' : 'condition',
          'left' => encode_expression(condition.left),
          'operator' => condition.operator,
          'right' => encode_expression(condition.right),
        }
        relation = condition.send(:child_relation)
        if relation
          result['relation'] = relation.to_s
          result['child'] = encode_condition(condition.child_condition)
        end
        result
      end

      def encode_variable(variable)
        {
          'type' => 'variable',
          'markup' => variable.raw.to_s,
          'line_number' => variable.line_number,
          'name' => encode_expression(variable.name),
          'filters' => variable.filters.map { |filter| encode_filter(filter) },
        }
      end

      def encode_filter(filter)
        name, args, kwargs = filter
        result = { 'name' => name.to_s, 'args' => args.map { |arg| encode_expression(arg) } }
        result['kwargs'] = encode_expression_hash(kwargs) if kwargs
        result
      end

      def encode_expression_hash(hash)
        hash.each_with_object({}) do |(key, value), result|
          result[key.to_s] = encode_expression(value)
        end
      end

      def encode_expression(value)
        case value
        when nil, true, false, Integer, String
          value
        when Float
          raise CompiledTemplateError, description + ' contains non-finite number' unless value.finite?
          value
        when ::Range
          { 'type' => 'range', 'start' => encode_expression(value.begin), 'finish' => encode_expression(value.end) }
        when VariableLookup
          {
            'type' => 'lookup',
            'name' => encode_expression(value.name),
            'lookups' => value.lookups.map { |lookup| encode_expression(lookup) },
            'command_flags' => value.instance_variable_get(:@command_flags).to_i,
          }
        when RangeLookup
          { 'type' => 'range_lookup', 'start' => encode_expression(value.start_obj), 'finish' => encode_expression(value.end_obj) }
        when Condition::MethodLiteral
          { 'type' => 'method_literal', 'method' => value.method_name.to_s }
        else
          raise CompiledTemplateError, "unsupported expression #{value.class}"
        end
      end

      def validate_primitive(value, description)
        case value
        when nil, true, false, Integer, Float, String
          value
        when Array
          value.map { |item| validate_primitive(item, description) }
        when Hash
          value.each_with_object({}) do |(key, item), result|
            raise CompiledTemplateError, "#{description} contains non-string key" unless key.is_a?(String)
            result[key] = validate_primitive(item, description)
          end
        else
          raise CompiledTemplateError, "#{description} contains unsupported #{value.class}"
        end
      end

      def empty_body
        { 'type' => 'body', 'blank' => true, 'nodes' => [] }
      end

      def template_name(template)
        name = template.name || '__root__'
        raise CompiledTemplateError, 'template name must be a string' unless name.is_a?(String)
        raise CompiledTemplateError, 'template name is empty' if name.empty?
        raise CompiledTemplateError, 'template name is too long' if name.length > DEFAULT_LIMITS[:name_length]
        name
      end

      def error_mode(template)
        template.instance_variable_get(:@error_mode) || template.root.parse_context.error_mode
      end

      def type_name(node)
        node.class.name.split('::').last.downcase
      end
    end

    class Decoder
      def initialize(environment:, limits:, validate_filters:)
        @environment = environment
        @limits = DEFAULT_LIMITS.merge(limits || {})
        @validate_filters = validate_filters
        @templates = {}
        @instances = {}
        @parse_contexts = {}
        @filter_names = {}
        @references = {}
        @node_count = 0
        @reference_visited = nil
      end

      def load(payload)
        data = parse_payload(payload)
        validate_header(data)
        @templates = validate_hash(data.fetch('templates'), 'templates')
        raise_compiled_error('too many templates') if @templates.size > limit(:templates)

        root_name = data.fetch('root')
        validate_template_name(root_name)
        @templates.each_key { |name| build_template(name) }
        validate_references(root_name)

        @instances.each_value do |template|
          template.instance_variable_set(:@compiled_partials, @instances)
        end
        @instances.fetch(root_name) { raise_compiled_error("missing root template #{root_name.inspect}") }
      end

      private

      def parse_payload(payload)
        text = payload.to_s.to_str
        raise_compiled_error('compiled template payload is empty') if text.empty?
        raise_compiled_error('compiled template payload is too large') if text.bytesize > limit(:bytes)
        JSON.parse(text, max_nesting: Block::MAX_DEPTH * 2)
      rescue JSON::JSONError => error
        raise_compiled_error("invalid compiled template JSON: #{error.message}")
      end

      def validate_header(data)
        validate_hash!(data, 'compiled template')
        raise_compiled_error("unsupported format #{data['format'].inspect}") unless data['format'] == FORMAT
        version = data['version']
        raise_compiled_error("unsupported compiled template version #{version.inspect}") unless version == VERSION
      end

      def validate_references(root_name)
        visit_reference(root_name, {})
      end

      def visit_reference(name, path)
        raise_compiled_error('circular render dependency ' + name.inspect) if path[name]
        @reference_visited ||= {}
        return if @reference_visited[name]

        @reference_visited[name] = true
        references = @references[name] || []
        if references.size > limit(:references_per_template)
          raise_compiled_error('too many render dependencies in ' + name.inspect)
        end
        path[name] = true
        references.each do |reference|
          unless @instances.key?(reference)
            raise_compiled_error('missing render dependency ' + reference.inspect + ' referenced by ' + name.inspect)
          end
          visit_reference(reference, path)
        end
      ensure
        path.delete(name)
      end

      def build_template(name)
        return @instances[name] if @instances.key?(name)

        data = @templates.fetch(name) { raise_compiled_error("missing template #{name.inspect}") }
        validate_hash!(data, "template #{name.inspect}")
        validate_template_name(name)
        unless data['name'] == name
          raise_compiled_error('template name mismatch for ' + name.inspect)
        end
        @node_count = 0
        error_mode = validate_error_mode(validate_string(data.fetch('error_mode'), 'error_mode', name))
        validate_array(data.fetch('references'), 'references', name).each do |reference|
          validate_template_name(reference)
        end
        parse_context = ParseContext.new(environment: @environment, error_mode: error_mode)
        @parse_contexts[name] = parse_context
        template = Template.allocate
        template.send(:initialize, environment: @environment)
        template.name = name
        template.instance_variable_set(:@error_mode, error_mode)
        unless data['line_numbers'].is_a?(TrueClass) || data['line_numbers'].is_a?(FalseClass)
          raise_compiled_error("line_numbers must be a boolean in #{name.inspect}")
        end
        template.instance_variable_set(:@line_numbers, data.fetch('line_numbers'))
        @instances[name] = template
        root_data = data.fetch('root')
        validate_hash!(root_data, "document in #{name.inspect}")
        unless root_data['type'] == 'document'
          raise_compiled_error("unknown node type #{root_data['type'].inspect} in #{name.inspect}")
        end
        document = Document.new(parse_context, body: decode_body(root_data.fetch('body'), name, 0))
        declared_references = data.fetch('references').sort
        encoded_references = (@references[name] || []).sort
        unless declared_references == encoded_references
          raise_compiled_error("invalid render references in #{name.inspect}")
        end
        template.root = document
      rescue KeyError => error
        raise_compiled_error("missing #{error.key} in template #{name.inspect}")
      end

      def decode_body(data, template_name, depth)
        validate_hash!(data, "node in #{template_name.inspect}")
        raise_compiled_error("node nesting too deep in #{template_name.inspect}") if depth > limit(:depth)
        nodes_data = validate_array(data.fetch('nodes'), "nodes in #{template_name.inspect}")
        count_node!(nodes_data.length, template_name)
        nodes = nodes_data.map { |node| decode_node(node, template_name, depth + 1) }
        blank = data.fetch('blank')
        unless blank.is_a?(TrueClass) || blank.is_a?(FalseClass)
          raise_compiled_error("blank must be a boolean in #{template_name.inspect}")
        end
        BlockBody.compiled(nodes, blank)
      rescue KeyError => error
        raise_compiled_error("missing #{error.key} in template #{template_name.inspect}")
      end

      def decode_node(data, template_name, depth)
        return validate_string(data, 'text node', template_name) if data.is_a?(String)
        unless data.is_a?(Hash)
          raise_compiled_error('node must be a string or object in ' + template_name.inspect)
        end
        validate_hash!(data, "node in #{template_name.inspect}")
        type = validate_string(data.fetch('type'), 'node type', template_name)

        case type
        when 'variable'
          decode_variable(data, template_name)
        when 'body'
          decode_body(data, template_name, depth)
        else
          decode_tag(type, data, template_name, depth)
        end
      rescue KeyError => error
        raise_compiled_error("missing #{error.key} in #{type || 'node'} in #{template_name.inspect}")
      end

      def decode_tag(type, data, template_name, depth)
        method_name = "decode_#{type}_tag"
        unless respond_to?(method_name, true)
          raise_compiled_error("unknown node type #{type.inspect} in #{template_name.inspect}")
        end
        send(method_name, data, template_name, depth).tap do |tag|
          if data.key?('tag_name')
            tag_name = validate_string(data.fetch('tag_name'), 'tag name', template_name)
            tag.instance_variable_set(:@tag_name, tag_name)
          end
          if data.key?('markup')
            tag.instance_variable_set(:@markup, validate_string(data.fetch('markup'), 'tag markup', template_name))
          end
        end
      end

      def decode_echo_tag(data, template_name, _depth)
        Echo.compiled('echo', '', context_for(template_name), line_number: line_number(data)).tap do |tag|
          tag.instance_variable_set(:@variable, decode_variable(data.fetch('variable'), template_name))
        end
      end

      def decode_assign_tag(data, template_name, _depth)
        Assign.compiled('assign', '', context_for(template_name), line_number: line_number(data)).tap do |tag|
        tag.instance_variable_set(:@to, validate_string(data.fetch('to'), 'assign target', template_name))
        validate_variable_name(tag.instance_variable_get(:@to), 'assign target', template_name)
          tag.instance_variable_set(:@from, decode_variable(data.fetch('from'), template_name))
        end
      end

      def decode_increment_tag(data, template_name, _depth)
        build_simple_tag(Increment, 'increment', data, template_name, 'variable_name')
      end

      def decode_decrement_tag(data, template_name, _depth)
        build_simple_tag(Decrement, 'decrement', data, template_name, 'variable_name')
      end

      def decode_break_tag(data, template_name, _depth)
        Break.compiled('break', '', context_for(template_name), line_number: line_number(data))
      end

      def decode_continue_tag(data, template_name, _depth)
        Continue.compiled('continue', '', context_for(template_name), line_number: line_number(data))
      end

      def decode_inline_comment_tag(data, template_name, _depth)
        markup = validate_string(data.fetch('markup'), 'inline comment markup', template_name)
        tag = InlineComment.compiled('#', markup, context_for(template_name), line_number: line_number(data))
        tag.instance_variable_set(:@blank, true)
        tag
      end

      def decode_capture_tag(data, template_name, depth)
        build_block_tag(Capture, 'capture', data, template_name, depth).tap do |tag|
        tag.instance_variable_set(:@to, validate_string(data.fetch('to'), 'capture target', template_name))
        validate_variable_name(tag.instance_variable_get(:@to), 'capture target', template_name)
        end
      end

      def decode_ifchanged_tag(data, template_name, depth)
        build_block_tag(Ifchanged, 'ifchanged', data, template_name, depth)
      end

      def decode_comment_tag(data, template_name, _depth)
        Comment.compiled('comment', '', context_for(template_name), line_number: line_number(data), body: BlockBody.compiled([], true))
      end

      def decode_raw_tag(data, template_name, _depth)
        tag = Raw.compiled('raw', '', context_for(template_name), line_number: line_number(data))
        body = validate_string(data.fetch('raw_body'), 'raw body', template_name)
        tag.instance_variable_set(:@body, body)
        tag.instance_variable_set(:@blank, body.empty?)
        tag
      end

      def decode_doc_tag(data, template_name, _depth)
        tag = Doc.compiled('doc', '', context_for(template_name), line_number: line_number(data))
        body = validate_string(data.fetch('raw_body'), 'doc body', template_name)
        tag.instance_variable_set(:@body, body)
        tag.instance_variable_set(:@blank, body.empty?)
        tag
      end

      def decode_if_tag(data, template_name, depth)
        tag = If.compiled('if', '', context_for(template_name), line_number: line_number(data))
        tag.instance_variable_set(:@blocks, decode_conditions(data, template_name, depth))
        tag.instance_variable_set(:@blank, true)
        tag
      end

      def decode_unless_tag(data, template_name, depth)
        tag = Unless.compiled('unless', '', context_for(template_name), line_number: line_number(data))
        tag.instance_variable_set(:@blocks, decode_conditions(data, template_name, depth))
        tag.instance_variable_set(:@blank, true)
        tag
      end

      def decode_case_tag(data, template_name, depth)
        tag = Case.compiled('case', '', context_for(template_name), line_number: line_number(data))
        tag.instance_variable_set(:@left, decode_expression(data.fetch('left'), template_name))
        tag.instance_variable_set(:@blocks, decode_case_conditions(data, template_name, depth))
        tag.instance_variable_set(:@blank, true)
        tag
      end

      def decode_for_tag(data, template_name, depth)
        tag = For.compiled('for', '', context_for(template_name), line_number: line_number(data))
        variable_name = validate_string(data.fetch('variable_name'), 'for variable', template_name)
        validate_variable_name(variable_name, 'for variable', template_name)
        collection = decode_expression(data.fetch('collection'), template_name)
        source = validate_string(data.fetch('collection_source'), 'for source', template_name)
        tag.instance_variable_set(:@variable_name, variable_name)
        tag.instance_variable_set(:@collection_name, collection)
        tag.instance_variable_set(:@name, "#{variable_name}-#{source}")
        tag.instance_variable_set(:@reversed, data.fetch('reversed') == true)
        tag.instance_variable_set(:@for_block, decode_body(data.fetch('body'), template_name, depth))
        tag.instance_variable_set(:@else_block, decode_optional_body(data['else_body'], template_name, depth))
        tag.instance_variable_set(:@from, data.key?('from') ? decode_for_attribute(data.fetch('from'), template_name) : nil)
        tag.instance_variable_set(:@limit, data.key?('limit') ? decode_expression(data.fetch('limit'), template_name) : nil)
        tag.instance_variable_set(:@blank, true)
        tag
      end

      def decode_tablerow_tag(data, template_name, depth)
        tag = TableRow.compiled('tablerow', '', context_for(template_name), line_number: line_number(data))
        tag.instance_variable_set(:@variable_name, validate_string(data.fetch('variable_name'), 'tablerow variable', template_name))
        validate_variable_name(tag.instance_variable_get(:@variable_name), 'tablerow variable', template_name)
        tag.instance_variable_set(:@collection_name, decode_expression(data.fetch('collection'), template_name))
        tag.instance_variable_set(:@attributes, decode_expression_hash(data.fetch('attributes'), template_name))
        tag.instance_variable_set(:@body, decode_body(data.fetch('body'), template_name, depth))
        tag.instance_variable_set(:@blank, true)
        tag
      end

      def decode_cycle_tag(data, template_name, _depth)
        tag = Cycle.compiled('cycle', '', context_for(template_name), line_number: line_number(data))
        variables = validate_array(data.fetch('variables'), 'cycle variables', template_name)
        decoded_variables = variables.map { |value| decode_expression(value, template_name) }
        tag.instance_variable_set(:@variables, decoded_variables)
        tag.instance_variable_set(:@is_named, data.fetch('named') == true)
        if data.fetch('named')
          tag.instance_variable_set(:@name, decode_expression(data.fetch('name'), template_name))
        else
          stable_key = data['stable_key']
          stable_key = validate_string(stable_key, 'cycle key', template_name) unless stable_key.nil?
          tag.instance_variable_set(:@name, stable_key || decoded_variables.to_s)
          tag.compiled_counter_key = stable_key
        end
        tag.instance_variable_set(:@blank, false)
        tag
      end

      def decode_render_tag(data, template_name, _depth)
        decode_partial_tag(Render, 'render', data, template_name)
      end

      def decode_include_tag(data, template_name, _depth)
        decode_partial_tag(Include, 'include', data, template_name)
      end

      def decode_tag_tag(data, template_name, depth)
        tag_name = validate_string(data.fetch('tag_name'), 'custom tag name', template_name)
        unless tag_name.match?(/\A(?:#|[a-zA-Z_][a-zA-Z0-9_]*)\z/)
          raise_compiled_error("invalid custom tag name #{tag_name.inspect} in #{template_name.inspect}")
        end
        klass = @environment.tag_for_name(tag_name)
        unless klass
          raise_compiled_error("missing registered tag #{tag_name.inspect} in template #{template_name.inspect}")
        end

        markup = validate_string(data.fetch('markup'), 'custom tag markup', template_name)
        payload = data.key?('payload') ? validate_primitive(data.fetch('payload'), 'custom tag payload', template_name) : nil
        tag_data = { 'tag_name' => tag_name, 'markup' => markup, 'line_number' => line_number(data), 'payload' => payload }
        tag_data['body'] = data['body'] if data.key?('body')
        tag_data['raw_body'] = data['raw_body'] if data.key?('raw_body')
        tag = if klass <= Block
          klass.from_compiled_tag(tag_data, context_for(template_name)) do |body_data|
            decode_body(body_data, template_name, depth)
          end
        else
          klass.from_compiled_tag(tag_data, context_for(template_name))
        end
        raise_compiled_error("tag #{tag_name.inspect} did not return a Liquid::Tag in #{template_name.inspect}") unless tag.is_a?(Tag)
        tag
      end

      def decode_partial_tag(klass, type, data, template_name)
        tag = klass.compiled(type, '', context_for(template_name), line_number: line_number(data))
        template_expr = decode_expression(data.fetch('template'), template_name)
        if type == 'render' && !template_expr.is_a?(String)
          raise_compiled_error("render dependency must be a static string in #{template_name.inspect}")
        end
        tag.instance_variable_set(:@template_name_expr, template_expr)
        tag.instance_variable_set(:@variable_name_expr, data['variable'].nil? ? nil : decode_expression(data.fetch('variable'), template_name))
        if data['alias_name'].nil?
          tag.instance_variable_set(:@alias_name, nil)
        else
          alias_name = validate_string(data.fetch('alias_name'), 'alias name', template_name)
          unless alias_name.match?(/\A[a-zA-Z0-9_-]+\z/)
            raise_compiled_error("invalid alias name #{alias_name.inspect} in #{template_name.inspect}")
          end
          tag.instance_variable_set(:@alias_name, alias_name)
        end
        tag.instance_variable_set(:@is_for_loop, data.fetch('for_loop') == true)
        tag.instance_variable_set(:@attributes, decode_expression_hash(data.fetch('attributes'), template_name))
        register_dependency(template_name, template_expr)
        tag
      end

      def register_dependency(template_name, expression)
        return unless expression.is_a?(String)
        validate_partial_name(expression)
        references = (@references[template_name] ||= [])
        references << expression unless references.include?(expression)
      end

      def build_simple_tag(klass, tag_name, data, template_name, field)
        tag = klass.compiled(tag_name, '', context_for(template_name), line_number: line_number(data))
        tag.instance_variable_set(:@variable_name, validate_string(data.fetch(field), field, template_name))
        validate_variable_name(tag.instance_variable_get(:@variable_name), field, template_name)
        tag
      end

      def build_block_tag(klass, tag_name, data, template_name, depth)
        tag = klass.compiled(tag_name, '', context_for(template_name), line_number: line_number(data))
        tag.instance_variable_set(:@body, decode_body(data.fetch('body'), template_name, depth))
        tag.instance_variable_set(:@blank, data.fetch('body').fetch('blank') == true) if klass == Ifchanged
        tag
      end

      def decode_conditions(data, template_name, depth)
        validate_array(data.fetch('blocks'), 'condition blocks', template_name).map do |block|
          decode_condition_block(block, template_name, depth, false)
        end
      end

      def decode_case_conditions(data, template_name, depth)
        left = decode_expression(data.fetch('left'), template_name)
        validate_array(data.fetch('blocks'), 'case blocks', template_name).map do |block|
          decode_condition_block(block, template_name, depth, true, left)
        end
      end

      def decode_condition_block(block, template_name, depth, case_block, case_left = nil)
        validate_hash!(block, "condition in #{template_name.inspect}")
        condition = decode_condition(block.fetch('condition'), template_name, case_block, case_left)
        condition.attach(decode_body(block.fetch('body'), template_name, depth))
        condition
      end

      def decode_condition(data, template_name, case_block = false, case_left = nil)
        validate_hash!(data, "condition in #{template_name.inspect}")
        type = validate_string(data.fetch('type'), 'condition type', template_name)
        if type == 'else'
          condition = ElseCondition.new
        else
          left = case_block ? case_left : decode_expression(data.fetch('left'), template_name)
          operator = data['operator'].nil? ? nil : validate_operator(data.fetch('operator'), template_name)
          right = data['right'].nil? ? nil : decode_expression(data.fetch('right'), template_name)
          condition = Condition.compiled(left, operator, right)
          if data.key?('relation')
            relation = validate_string(data.fetch('relation'), 'boolean relation', template_name)
            raise_compiled_error("invalid boolean relation #{relation.inspect} in #{template_name.inspect}") unless %w[and or].include?(relation)
            child = decode_condition(data.fetch('child'), template_name, case_block, case_left)
            condition = Condition.compiled(left, operator, right, child_relation: relation.to_sym, child_condition: child)
          end
        end
        condition
      end

      def validate_operator(operator, template_name)
        return operator if Condition.operators.key?(operator)
        raise_compiled_error("unknown operator #{operator.inspect} in #{template_name.inspect}")
      end

      def decode_optional_body(data, template_name, depth)
        return nil if data.nil?
        decode_body(data, template_name, depth)
      end

      def decode_for_attribute(value, template_name)
        return :continue if value == 'continue'
        decode_expression(value, template_name)
      end

      def decode_variable(data, template_name)
        validate_hash!(data, "variable in #{template_name.inspect}")
        name = decode_expression(data.fetch('name'), template_name)
        filters = validate_array(data.fetch('filters'), 'filters', template_name).map do |filter|
          decode_filter(filter, template_name)
        end
        Variable.compiled(name, filters, markup: validate_string(data.fetch('markup'), 'variable markup', template_name), line_number: line_number(data))
      end

      def decode_filter(data, template_name)
        validate_hash!(data, "filter in #{template_name.inspect}")
        name = validate_string(data.fetch('name'), 'filter name', template_name)
        validate_filter_name(name, template_name)
        args = validate_array(data.fetch('args'), 'filter arguments', template_name).map do |arg|
          decode_expression(arg, template_name)
        end
        kwargs = data.key?('kwargs') ? decode_expression_hash(data.fetch('kwargs'), template_name) : nil
        kwargs ? [name, args, kwargs] : [name, args]
      end

      def validate_filter_name(name, template_name)
        unless name.match?(/\A[a-zA-Z_][a-zA-Z0-9_]*[!?=]?\z/)
          raise_compiled_error("invalid filter name #{name.inspect} in #{template_name.inspect}")
        end
        return unless @validate_filters
        @filter_names[name] ||= begin
          available = @environment.filter_method_names.include?(name)
          unless available
            raise_compiled_error("missing registered filter #{name.inspect} in template #{template_name.inspect}")
          end
          true
        end
      end

      def decode_expression_hash(data, template_name)
        validate_hash!(data, 'expression map', template_name)
        data.each_with_object({}) do |(key, value), result|
          key_name = validate_string(key, 'expression key', template_name)
          unless key_name.match?(/\A[a-zA-Z_][a-zA-Z0-9_-]*\z/)
            raise_compiled_error("invalid expression key #{key_name.inspect} in #{template_name.inspect}")
          end
          result[key_name] = decode_expression(value, template_name)
        end
      end

      def decode_expression(data, template_name)
        if data.nil? || data.is_a?(TrueClass) || data.is_a?(FalseClass) || data.is_a?(Integer) || data.is_a?(Float) || data.is_a?(String)
          validate_primitive(data, 'expression', template_name)
          return data
        end
        validate_hash!(data, "expression in #{template_name.inspect}")
        case data.fetch('type')
        when 'range'
          Range.new(integer_expression(data.fetch('start'), template_name), integer_expression(data.fetch('finish'), template_name))
        when 'range_lookup'
          RangeLookup.new(decode_expression(data.fetch('start'), template_name), decode_expression(data.fetch('finish'), template_name))
        when 'lookup'
          name = decode_expression(data.fetch('name'), template_name)
          lookups = validate_array(data.fetch('lookups'), 'lookups', template_name).map do |lookup|
            decode_expression(lookup, template_name)
          end
          flags = data.fetch('command_flags')
          validate_integer!(flags, 'command flags', template_name)
          max_flags = (1 << lookups.length) - 1
          unless flags >= 0 && (flags & max_flags) == flags
            raise_compiled_error("invalid command flags in #{template_name.inspect}")
          end
          VariableLookup.compiled(name, lookups, flags)
        when 'method_literal'
          method = validate_string(data.fetch('method'), 'method literal', template_name)
          key = method.delete_suffix('?')
          unless %w[blank empty].include?(key)
            raise_compiled_error("unknown method literal #{method.inspect} in #{template_name.inspect}")
          end
          Condition.method_literal(key)
        else
          raise_compiled_error("unknown expression type #{data['type'].inspect} in #{template_name.inspect}")
        end
      end

      def integer_expression(data, template_name)
        value = decode_expression(data, template_name)
        unless value.is_a?(Integer)
          raise_compiled_error("range endpoint must be an integer in #{template_name.inspect}")
        end
        value
      end

      def validate_primitive(data, description, template_name)
        case data
        when nil, true, false, Integer
          validate_string_length(data, description) if data.is_a?(String)
          data
        when Float
          raise_compiled_error("#{description} contains non-finite number in #{template_name.inspect}") unless data.finite?
          data
        when String
          validate_string_length(data, description)
          data
        when Array
          data.each { |item| validate_primitive(item, description, template_name) }
        when Hash
          data.each do |key, value|
            validate_string(key, description, template_name)
            validate_primitive(value, description, template_name)
          end
        else
          raise_compiled_error("#{description} contains unsupported #{data.class} in #{template_name.inspect}")
        end
      end

      def context_for(template_name)
        @parse_contexts.fetch(template_name) { raise_compiled_error("unknown template reference #{template_name.inspect}") }
      end

      def count_node!(count, template_name)
        @node_count += count
        raise_compiled_error("too many nodes in #{template_name.inspect}") if @node_count > limit(:nodes_per_template)
      end

      def line_number(data)
        return nil unless data.key?('line_number')
        value = data.fetch('line_number')
        return nil if value.nil?
        validate_integer!(value, 'line number', data)
        value
      end

      def validate_integer!(value, label, _template_name = nil)
        return value if value.is_a?(Integer)
        raise_compiled_error("#{label} must be an integer")
      end

      def validate_boolean(value, label, template_name)
        return value if value.is_a?(TrueClass) || value.is_a?(FalseClass)
        raise_compiled_error("#{label} must be a boolean in #{template_name.inspect}")
      end

      def validate_variable_name(value, label, template_name)
        unless value.match?(/\A[a-zA-Z0-9_.-]+\z/)
          raise_compiled_error("invalid #{label} #{value.inspect} in #{template_name.inspect}")
        end
      end

      def validate_template_name(name)
        validate_string!(name, 'template name')
        raise_compiled_error('template name is too long') if name.length > limit(:name_length)
        unless name == '__root__' || name.match?(/\A[a-zA-Z0-9_][a-zA-Z0-9_\/.-]*\z/)
          raise_compiled_error('invalid template name ' + name.inspect)
        end
      end

      def validate_partial_name(name)
        validate_string!(name, 'render dependency name')
        if name.length > limit(:name_length) || !name.match?(/\A[a-zA-Z0-9_][a-zA-Z0-9_\/.-]*\z/)
          raise_compiled_error('invalid render dependency name ' + name.inspect)
        end
      end

      def validate_error_mode(mode)
        symbol = mode.to_sym
        unless %i[lax warn strict strict2 rigid].include?(symbol)
          raise_compiled_error("unknown error mode #{mode.inspect}")
        end
        symbol
      end

      def validate_string(value, label, template_name = nil)
        raise_compiled_error("#{label} must be a string") unless value.is_a?(String)
        validate_string_length(value, label)
        value
      end

      def validate_string!(value, label)
        raise_compiled_error("#{label} must be a string") unless value.is_a?(String)
        raise_compiled_error("#{label} cannot be empty") if value.empty?
        value
      end

      def validate_string_length(value, label)
        raise_compiled_error("#{label} is too long") if value.length > limit(:string_length)
        value
      end

      def validate_array(value, label, template_name = nil)
        location = template_name ? " in #{template_name.inspect}" : ''
        raise_compiled_error("#{label} must be an array#{location}") unless value.is_a?(Array)
        value
      end

      def validate_hash(value, label)
        raise_compiled_error("#{label} must be an object") unless value.is_a?(Hash)
        value
      end

      def validate_hash!(value, label, template_name = nil)
        location = template_name ? " in #{template_name.inspect}" : ''
        raise_compiled_error("#{label} must be an object#{location}") unless value.is_a?(Hash)
        value
      end

      def limit(name)
        value = @limits.fetch(name)
        raise_compiled_error("invalid compiled template limit #{name}") unless value.is_a?(Integer) && value.positive?
        value
      end

      def raise_compiled_error(message)
        raise CompiledTemplateError, message
      end
    end
  end
end
