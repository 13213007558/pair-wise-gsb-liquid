# frozen_string_literal: true

module Liquid
  module CompiledTemplate
    class Loader
      OPERATORS = (Condition.operators.keys - %w[<>]).freeze

      class MissingCustomTag < Tag
        def initialize(name, template_name, line)
          @missing_name = name
          @missing_template_name = template_name
          @line_number = line
        end

        def error
          error = CompiledTemplateError.new(
            "unknown tag #{@missing_name.inspect} in template #{@missing_template_name.inspect}"
          )
          error.template_name = @missing_template_name
          error.line_number = @line_number
          error
        end
      end

      def initialize(environment:, name:, max_nodes:, max_depth:, max_string_bytes:, max_partials:)
        @environment = environment
        @name_override = name
        @max_nodes = max_nodes
        @max_depth = max_depth
        @max_string_bytes = max_string_bytes
        @max_partials = max_partials
        @nodes = 0
        @string_bytes = 0
        @references = Hash.new { |hash, key| hash[key] = { 'render' => [], 'include' => [] } }
        @template_name = nil
        @used_filters = {}
        @used_custom_tags = Set.new
        @missing_custom_tags = []
      end

      def load(payload)
        payload = payload.read if payload.respond_to?(:read)
        check_payload!(payload)
        data = JSON.parse(payload, max_nesting: @max_depth * 8 + 20)
        root_name = data.is_a?(Hash) ? (@name_override || data['name'] || 'compiled_template') : nil
        @template_name = root_name if root_name.is_a?(String)
        validate_name!(@name_override, :template_name) if @name_override
        check_package!(data)
        root_name = @name_override || string!(data['name'], 'name')
        raise_compiled('root template name must match reference naming rules') unless valid_reference?(root_name)
        partial_data = hash!(data['partials'], 'partials')
        if partial_data.key?(root_name)
          raise_compiled("partial name #{root_name.inspect} conflicts with root template")
        end

        compiled_partials = build_partials(partial_data, root_name)
        root_template = build_template(hash!(data['template'], 'template'), root_name, false)
        compiled_partials[root_name] = root_template
        @template_name = root_name
        check_declared_extensions!(data)
        verify_references!(compiled_partials, root_name)
        root_template.instance_variable_set(:@compiled_partials, compiled_partials)
        root_template
      rescue JSON::ParserError => e
        raise CompiledTemplateError, "invalid JSON: #{e.message}"
      rescue CompiledTemplateError
        raise
      rescue Liquid::Error => e
        e.template_name ||= @template_name
        raise
      end

      private

      def check_payload!(payload)
        unless payload.is_a?(String)
          raise_compiled("payload must be a String or respond to read")
        end
        unless payload.bytesize <= CompiledTemplate::MAX_PAYLOAD_BYTES
          raise_compiled("payload exceeds #{CompiledTemplate::MAX_PAYLOAD_BYTES} bytes")
        end
        unless payload.valid_encoding?
          raise_compiled("payload has invalid encoding")
        end
      end

      def check_package!(data)
        unless data.is_a?(Hash)
          raise_compiled("package must be an object")
        end
        unless data['format'] == CompiledTemplate::FORMAT
          raise_compiled("unsupported format #{data['format'].inspect}")
        end
        unless data['version'] == CompiledTemplate::VERSION
          raise_compiled("unsupported version #{data['version'].inspect}; expected #{CompiledTemplate::VERSION}")
        end

        validate_declared_extension_names!(array_of_strings!(data['filters'], 'filters'), :filter)
        validate_declared_extension_names!(array_of_strings!(data['tags'], 'tags'), :tag)
      end

      def check_declared_extensions!(data)
        raise(@missing_custom_tags.first.error) unless @missing_custom_tags.empty?
        check_extensions!(data['filters'], :filter)
        check_extensions!(data['tags'] - @used_custom_tags.to_a, :tag)
        @used_filters.sort_by { |entry| entry[1] || 1_000_000_000 }.each do |name, line|
          next if @environment.filter_method_names.include?(name)

          check_filter_extension!(name, line)
        end
      end

      def validate_declared_extension_names!(names, kind)
        names.each { |name| validate_name!(name, kind) }
      end

      def check_extensions!(names, kind)
        names.each do |name|
          validate_name!(name, kind)
          next if kind == :filter ? @environment.filter_method_names.include?(name) : @environment.tag_for_name(name)

          if kind == :filter
            error = UndefinedFilter.new("undefined filter #{name} in template #{@template_name.inspect}")
          else
            error = CompiledTemplateError.new("unknown tag #{name.inspect} in template #{@template_name.inspect}")
          end
          error.template_name = @template_name
          raise error
        end
      end

      def build_partials(partial_data, root_name)
        unless partial_data.size <= @max_partials
          raise_compiled("partial count exceeds #{@max_partials}")
        end

        partial_data.each do |name, template_data|
          unless name.is_a?(String) && valid_reference?(name)
            raise_compiled("invalid partial name #{name.inspect}")
          end
          hash!(template_data, "partials[#{name.inspect}]")
        end

        compiled = {}
        partial_data.each do |name, template_data|
          compiled[name] = build_template(template_data, name, true)
        end
        compiled[root_name] = nil
        compiled
      end

      def build_template(data, name, partial)
        check_template_data!(data)
        previous_name = @template_name
        previous_data = @current_template_data
        previous_partial = @current_template_partial
        @template_name = name
        @current_template_data = data
        @current_template_partial = partial

        template = Template.new(environment: @environment)
        parse_context = ParseContext.new(
          environment: @environment,
          error_mode: error_mode(data),
          line_numbers: true,
        )
        parse_context.partial = partial
        root = node(hash!(data['root'], 'root'), 0)
        document = Document.allocate
        document.instance_variable_set(:@parse_context, parse_context)
        document.instance_variable_set(:@body, root)
        raise_compiled('document root must be a body node') unless root.is_a?(BlockBody)
        root.freeze

        template.root = document
        template.name = name
        template.instance_variable_set(:@error_mode, parse_context.error_mode)
        template.instance_variable_set(:@warnings, parse_context.warnings)
        template.instance_variable_set(:@line_numbers, true)
        template
      ensure
        @template_name = previous_name
        @current_template_data = previous_data
        @current_template_partial = previous_partial
      end

      def error_mode(data)
        value = string!(data['error_mode'], 'error_mode')
        unless CompiledTemplate::ERROR_MODES.include?(value)
          raise_compiled("unsupported error mode #{value.inspect}")
        end
        value.to_sym
      end

      def check_template_data!(data)
        hash!(data, 'template')
        name = data['name']
        error_mode(data)
        raise_compiled('template name must be a string') unless name.is_a?(String)
        raise_compiled('template name is too long') if name.bytesize > CompiledTemplate::MAX_STRING_BYTES
        raise_compiled('template partial flag must be a boolean') unless data['partial'].equal?(true) || data['partial'].equal?(false)
        hash!(data['root'], 'template root')
        references = hash!(data['references'], 'template references')
        references['render'] ||= []
        references['include'] ||= []
        %w[render include].each do |type|
          array_of_strings!(references[type], "#{type} references").each do |reference|
            unless valid_reference?(reference)
              raise_compiled("invalid #{type} reference #{reference.inspect}")
            end
          end
        end
      end

      def node(data, depth)
        budget_node!
        return string!(data, 'node') if data.is_a?(String)
        hash!(data, 'node')
        budget_depth!(depth + 1)

        type = string!(data['t'], 'node type')
        case type
        when 'document' then document_node(data, depth)
        when 'body' then body_node(data, depth)
        when 'variable' then variable_node(data)
        when 'if', 'unless' then conditional_node(data, type, depth)
        when 'case' then case_node(data, depth)
        when 'for' then for_node(data, depth)
        when 'tablerow' then tablerow_node(data, depth)
        when 'capture' then capture_node(data, depth)
        when 'ifchanged' then block_node(data, Ifchanged, depth)
        when 'comment' then tag_without_body(Comment, data)
        when 'raw' then raw_node(data)
        when 'doc' then doc_node(data)
        when 'assign' then assign_node(data)
        when 'echo' then echo_node(data)
        when 'increment', 'decrement' then counter_node(data, type)
        when 'cycle' then cycle_node(data)
        when 'break' then tag_without_body(Break, data)
        when 'continue' then tag_without_body(Continue, data)
        when '#' then tag_without_body(InlineComment, data)
        when 'render', 'include' then partial_tag_node(data, type)
        when 'custom', 'custom_tag' then custom_node(data, type, depth)
        else raise_compiled("unknown node type #{type.inspect}")
        end
      end

      def document_node(data, depth)
        root = node(hash!(data['body'], 'document body'), depth + 1)
        raise_compiled('document body must be a body node') unless root.is_a?(BlockBody)
        root
      end

      def body_node(data, depth)
        block_body = BlockBody.allocate
        block_body.instance_variable_set(:@blank, boolean!(data['blank'], 'body blank'))
        nodes = array!(data['nodes'], 'body nodes').map { |child| node(child, depth + 1) }
        block_body.instance_variable_set(:@nodelist, nodes)
        block_body.freeze
        block_body
      end

      def variable_node(data)
        variable = Variable.allocate
        variable.instance_variable_set(:@name, expression(data['name']))
        variable.instance_variable_set(:@filters, filters(data['filters'], line_number(data)))
        variable.instance_variable_set(:@line_number, line_number(data))
        variable.instance_variable_set(:@parse_context, current_parse_context)
        variable
      end

      def filters(data, line)
        array!(data, 'filters').map do |entry|
          filter = array!(entry, 'filter')
          raise_compiled('filter must have a name and arguments') unless filter.size.between?(2, 3)
          filter_name = filter_name!(filter[0])
          check_filter_extension!(filter_name, line)
          filter[0] = filter_name
          filter[1] = array!(filter[1], 'filter arguments').map { |argument| expression(argument) }
          filter[2] = kwargs!(filter[2]) if filter[2]
          filter
        end
      end

      def check_filter_extension!(name, line)
        @used_filters[name] = line unless @used_filters.key?(name)
      end

      def expression(data)
        case data
        when nil, true, false then data
        when Integer
          raise_compiled("integer exceeds supported range") unless data.abs <= CompiledTemplate::MAX_INTEGER_ABS
          data
        when String then string!(data, 'string expression')
        when Float
          raise_compiled('unsupported Float') unless data.finite?
          data
        when Hash
          case data['t']
          when 'nil' then nil
          when 'lookup' then lookup_expression(data)
          when 'range' then range_expression(data)
          when 'range_literal' then range_literal(data)
          when 'method' then method_expression(data)
          when 'symbol' then symbol_expression(data)
          else raise_compiled("unknown expression type #{data['t'].inspect}")
          end
        else raise_compiled("unsupported expression #{data.class}")
        end
      end

      def lookup_expression(data)
        lookup = VariableLookup.allocate
        lookup.instance_variable_set(:@name, expression(data['name']))
        lookups = array!(data['lookups'], 'lookup lookups').map { |item| expression(item) }
        flags = integer!(data['command_flags'], 'lookup command flags')
        unless flags >= 0 && flags < (1 << lookups.size)
          raise_compiled('invalid lookup command flags')
        end
        lookups.each_index do |index|
          command = (flags & (1 << index)) != 0
          if command && !CompiledTemplate::COMMAND_LOOKUPS.include?(lookups[index])
            raise_compiled('lookup command flags do not match command lookup')
          end
        end
        lookup.instance_variable_set(:@lookups, lookups)
        lookup.instance_variable_set(:@command_flags, flags)
        lookup
      end

      def range_expression(data)
        RangeLookup.new(expression(data['start']), expression(data['end']))
      end

      def range_literal(data)
        start = integer!(data['start'], 'range start')
        finish = integer!(data['end'], 'range end')
        unless start.abs <= CompiledTemplate::MAX_INTEGER_ABS && finish.abs <= CompiledTemplate::MAX_INTEGER_ABS
          raise_compiled('range integer exceeds supported range')
        end
        start..finish
      end

      def method_expression(data)
        name = string!(data['name'], 'method name').to_sym
        literals = Condition.instance_variable_get(:@@method_literals)
        literals.fetch(name) { raise_compiled("unknown method literal #{data['name'].inspect}") }
      end

      def symbol_expression(data)
        name = string!(data['name'], 'symbol name')
        raise_compiled("unsupported symbol #{name.inspect}") unless name == 'continue'
        :continue
      end

      def conditional_node(data, type, depth)
        klass = type == 'unless' ? Unless : If
        tag = allocated_tag(klass, type, data)
        blocks = array!(data['blocks'], 'condition blocks').map do |block_data|
          block = hash!(block_data, 'condition block')
          condition = condition(block['condition'])
          condition.attach(expect_body(node(block['body'], depth + 1)))
          condition
        end
        raise_compiled('condition requires at least one block') if blocks.empty?
        tag.instance_variable_set(:@blocks, blocks)
        tag
      end

      def condition(data)
        hash!(data, 'condition')
        operator = data['operator']
        unless operator.nil? || OPERATORS.include?(operator)
          raise_compiled("unknown operator #{operator.inspect}")
        end

        result = data['else'].equal?(true) ? ElseCondition.new : Condition.new
        result.left = expression(data['left'])
        result.operator = operator
        result.right = expression(data['right'])

        if data['child']
          relation = string!(data['relation'], 'condition relation')
          raise_compiled('unknown condition relation') unless %w[and or].include?(relation)
          result.send(relation, condition(data['child']))
        end
        result
      end

      def case_node(data, depth)
        tag = allocated_tag(Case, 'case', data)
        tag.instance_variable_set(:@left, expression(data['left']))
        blocks = []
        array!(data['blocks'], 'case blocks').each do |block_data|
          block = hash!(block_data, 'case block')
          body = expect_body(node(block['body'], depth + 1))
          array!(block['conditions'], 'case conditions').each do |condition_data|
            condition = condition(condition_data)
            condition.attach(body)
            blocks << condition
          end
        end
        tag.instance_variable_set(:@blocks, blocks)
        tag
      end

      def for_node(data, depth)
        tag = allocated_tag(For, 'for', data)
        tag.instance_variable_set(:@variable_name, string!(data['variable'], 'for variable'))
        tag.instance_variable_set(:@collection_name, expression(data['collection']))
        tag.instance_variable_set(:@name, string!(data['name'], 'for name'))
        tag.instance_variable_set(:@reversed, boolean!(data['reversed'], 'for reversed'))
        tag.instance_variable_set(:@limit, expression(data['limit']))
        tag.instance_variable_set(:@from, expression(data['from']))
        tag.instance_variable_set(:@for_block, body(data['body'], depth))
        tag.instance_variable_set(:@else_block, data['else_body'] ? body(data['else_body'], depth) : nil)
        tag
      end

      def tablerow_node(data, depth)
        tag = allocated_tag(TableRow, 'tablerow', data)
        tag.instance_variable_set(:@variable_name, string!(data['variable'], 'tablerow variable'))
        tag.instance_variable_set(:@collection_name, expression(data['collection']))
        attributes = kwargs!(data['attributes'], 'tablerow attributes')
        tag.instance_variable_set(:@attributes, attributes.transform_values { |value| expression(value) })
        tag.instance_variable_set(:@body, body(data['body'], depth))
        tag
      end

      def capture_node(data, depth)
        tag = allocated_tag(Capture, 'capture', data)
        tag.instance_variable_set(:@to, string!(data['to'], 'capture target'))
        tag.instance_variable_set(:@body, body(data['body'], depth))
        tag
      end

      def block_node(data, klass, depth)
        tag = allocated_tag(klass, data['t'], data)
        tag.instance_variable_set(:@body, body(data['body'], depth))
        tag
      end

      def raw_node(data)
        tag = allocated_tag(Raw, 'raw', data)
        tag.instance_variable_set(:@body, string!(data['body'], 'raw body'))
        tag
      end

      def doc_node(data)
        tag = allocated_tag(Doc, 'doc', data)
        tag.instance_variable_set(:@body, string!(data['body'], 'doc body'))
        tag
      end

      def assign_node(data)
        tag = allocated_tag(Assign, 'assign', data)
        tag.instance_variable_set(:@to, string!(data['to'], 'assign target'))
        tag.instance_variable_set(:@from, variable_from(data['value'], 'assign value'))
        tag
      end

      def echo_node(data)
        tag = allocated_tag(Echo, 'echo', data)
        tag.instance_variable_set(:@variable, variable_from(data['value'], 'echo value'))
        tag
      end

      def counter_node(data, type)
        klass = type == 'increment' ? Increment : Decrement
        tag = allocated_tag(klass, type, data)
        tag.instance_variable_set(:@variable_name, string!(data['variable'], "#{type} variable"))
        tag
      end

      def cycle_node(data)
        tag = allocated_tag(Cycle, 'cycle', data)
        variables = array!(data['variables'], 'cycle variables').map { |value| expression(value) }
        tag.instance_variable_set(:@variables, variables)
        tag.instance_variable_set(:@is_named, boolean!(data['named'], 'cycle named'))
        tag.instance_variable_set(:@name, expression(data['name']))
        tag
      end

      def partial_tag_node(data, type)
        klass = type == 'render' ? Render : Include
        tag = allocated_tag(klass, type, data)
        template_expression = expression(data['template'])
        reference(template_expression, type)
        tag.instance_variable_set(:@template_name_expr, template_expression)
        tag.instance_variable_set(:@variable_name_expr, expression(data['variable']))
        tag.instance_variable_set(:@is_for_loop, boolean!(data['for'], 'for loop'))
        tag.instance_variable_set(:@alias_name, optional_string(data['alias'], 'alias'))
        attributes = kwargs!(data['attributes'], "#{type} attributes")
        tag.instance_variable_set(:@attributes, attributes.transform_values { |value| expression(value) })
        tag
      end

      def tag_without_body(klass, data)
        allocated_tag(klass, data['t'], data)
      end

      def custom_node(data, type, depth)
        name = string!(data['tag'], 'custom tag name')
        @used_custom_tags << name
        klass = @environment.tag_for_name(name)
        unless klass.is_a?(Class) && klass.ancestors.include?(Liquid::Tag)
          missing = MissingCustomTag.allocate
          missing.send(:initialize, name, @template_name, data['line'])
          @missing_custom_tags << missing
          return missing
        end

        if type == 'custom' && klass.respond_to?(:from_liquid_compiled)
          tag = klass.from_liquid_compiled(data, loader: self, depth: depth)
          raise_compiled("custom tag #{name.inspect} returned #{tag.class}") unless tag.is_a?(Liquid::Tag)
          return tag
        end

        markup = string!(data['markup'], 'custom tag markup')
        parse_context = current_parse_context
        parse_context.line_number = line_number(data)
        tag = klass.allocate
        tag.send(:initialize, name, markup, parse_context)
        if data['body']
          body_data = hash!(data['body'], 'custom tag body')
          tag.instance_variable_set(:@body, body(body_data, depth))
        elsif !tag.is_a?(Block)
          tag.parse(parse_context.new_tokenizer(''))
        end
        tag.instance_variable_set(:@blank, boolean!(data['blank'], 'custom tag blank')) if data.key?('blank')
        tag
      end

      def allocated_tag(klass, name, data)
        tag = klass.allocate
        tag.instance_variable_set(:@tag_name, name)
        tag.instance_variable_set(:@markup, '')
        tag.instance_variable_set(:@parse_context, current_parse_context)
        tag.instance_variable_set(:@line_number, line_number(data))
        tag.instance_variable_set(:@blank, boolean!(data['blank'], 'tag blank')) if data.key?('blank')
        tag
      end

      def body(data, depth)
        expect_body(node(hash!(data, 'body'), depth + 1))
      end

      def expect_body(value)
        raise_compiled('expected a body node') unless value.is_a?(BlockBody)
        value
      end

      def variable_from(data, field)
        value = node(hash!(data, field), 0)
        raise_compiled("expected a variable node for #{field}") unless value.is_a?(Variable)
        value
      end

      def current_parse_context
        ParseContext.new(
          environment: @environment,
          error_mode: error_mode(@current_template_data),
          line_numbers: true,
          partial: @current_template_partial,
        )
      end

      def reference(expression_value, type)
        return unless expression_value.is_a?(String)
        unless valid_reference?(expression_value)
          raise_compiled("invalid #{type} dependency name #{expression_value.inspect}")
        end
        @references[@template_name][type] << expression_value
      end

      def verify_references!(partials, root_name)
        @references.each do |template_name, references|
          references.each do |type, names|
            names.uniq.each do |name|
              next if partials.key?(name)
              next if name == root_name && name != template_name

              error = CompiledTemplateError.new(
                "missing #{type} dependency #{name.inspect} referenced from #{template_name.inspect}"
              )
              error.template_name = template_name
              raise error
            end
          end
        end
      end

      def budget_node!
        @nodes += 1
        raise_compiled("node count exceeds #{@max_nodes}") if @nodes > @max_nodes
      end

      def budget_depth!(depth)
        raise_compiled("nesting depth exceeds #{@max_depth}") if depth > @max_depth
      end

      def string!(value, field)
        raise_compiled("#{field} must be a string") unless value.is_a?(String)
        @string_bytes += value.bytesize
        if value.bytesize > CompiledTemplate::MAX_STRING_BYTES
          raise_compiled("individual string exceeds #{CompiledTemplate::MAX_STRING_BYTES} bytes")
        end
        raise_compiled("string data exceeds #{@max_string_bytes} bytes") if @string_bytes > @max_string_bytes
        value
      end

      def hash!(value, field)
        raise_compiled("#{field} must be an object") unless value.is_a?(Hash)
        value
      end

      def array!(value, field)
        raise_compiled("#{field} must be an array") unless value.is_a?(Array)
        value
      end

      def kwargs!(value, field = 'keyword arguments')
        value ||= {}
        hash!(value, field)
        value.each_key do |key|
          unless key.is_a?(String) && key.match?(/\A[a-zA-Z_][a-zA-Z0-9_\-]*\z/)
            raise_compiled("invalid keyword name #{key.inspect} in #{field}")
          end
        end
        value
      end

      def boolean!(value, field)
        raise_compiled("#{field} must be a boolean") unless value.equal?(true) || value.equal?(false)
        value
      end

      def integer!(value, field)
        raise_compiled("#{field} must be an integer") unless value.is_a?(Integer)
        value
      end

      def optional_string(value, field)
        return nil if value.nil?
        string!(value, field)
      end

      def array_of_strings!(value, field)
        array!(value, field).each { |item| string!(item, field) }
      end

      def filter_name!(value)
        value = string!(value, 'filter name')
        validate_name!(value, :filter)
        value
      end

      def valid_reference?(value)
        value.match?(/\A[a-zA-Z0-9_][a-zA-Z0-9_\-\/]*\z/) && !value.include?('..')
      end

      def validate_name!(name, kind)
        patterns = {
          filter: /\A[a-zA-Z_][a-zA-Z0-9_]*[?=!]?\z/,
          tag: /\A(?:#|[a-zA-Z0-9_][a-zA-Z0-9_\-]*)\z/,
          template_name: /\A[a-zA-Z0-9_][a-zA-Z0-9_\-\/]*\z/,
        }
        pattern = patterns.fetch(kind) { valid_reference_pattern }
        raise_compiled("invalid #{kind} name #{name.inspect}") unless name.match?(pattern)
      end

      def valid_reference_pattern
        /\A[a-zA-Z0-9_][a-zA-Z0-9_\-\/]*\z/
      end

      def line_number(data)
        integer_line(data['line'])
      end

      def integer_line(value)
        return nil if value.nil?
        raise_compiled('line number must be an integer') unless value.is_a?(Integer)
        raise_compiled('line number must be positive') unless value.positive?
        value
      end

      def raise_compiled(message)
        error = CompiledTemplateError.new(message)
        error.template_name = @template_name
        raise error
      end
    end
  end
end
