# frozen_string_literal: true

module Liquid
  # Templates are central to liquid.
  # Interpreting templates is a two step process. First you compile the
  # source code you got. During compile time some extensive error checking is performed.
  # your code should expect to get some SyntaxErrors.
  #
  # After you have a compiled template you can then <tt>render</tt> it.
  # You can use a compiled template over and over again and keep it cached.
  #
  # Example:
  #
  #   template = Liquid::Template.parse(source)
  #   template.render('user_name' => 'bob')
  #
  class Template
    attr_accessor :root, :name
    attr_reader :resource_limits, :warnings

    attr_reader :profiler

    # {SpecializationInfo} for templates produced by {#specialize}; nil for a
    # template parsed normally.
    attr_accessor :specialization_info

    class << self
      # Sets how strict the parser should be.
      # :lax acts like liquid 2.5 and silently ignores malformed tags in most cases.
      # :warn is the default and will give deprecation warnings when invalid syntax is used.
      # :strict enforces correct syntax for most tags
      # :strict2 enforces correct syntax for all tags
      def error_mode=(mode)
        Deprecations.warn("Template.error_mode=", "Environment#error_mode=")
        Environment.default.error_mode = mode
      end

      def error_mode
        Environment.default.error_mode
      end

      def default_exception_renderer=(renderer)
        Deprecations.warn("Template.default_exception_renderer=", "Environment#exception_renderer=")
        Environment.default.exception_renderer = renderer
      end

      def default_exception_renderer
        Environment.default.exception_renderer
      end

      def file_system=(file_system)
        Deprecations.warn("Template.file_system=", "Environment#file_system=")
        Environment.default.file_system = file_system
      end

      def file_system
        Environment.default.file_system
      end

      def tags
        Environment.default.tags
      end

      def register_tag(name, klass)
        Deprecations.warn("Template.register_tag", "Environment#register_tag")
        Environment.default.register_tag(name, klass)
      end

      # Pass a module with filter methods which should be available
      # to all liquid views. Good for registering the standard library
      def register_filter(mod)
        Deprecations.warn("Template.register_filter", "Environment#register_filter")
        Environment.default.register_filter(mod)
      end

      private def default_resource_limits=(limits)
        Deprecations.warn("Template.default_resource_limits=", "Environment#default_resource_limits=")
        Environment.default.default_resource_limits = limits
      end

      def default_resource_limits
        Environment.default.default_resource_limits
      end

      # creates a new <tt>Template</tt> object from liquid source code
      # To enable profiling, pass in <tt>profile: true</tt> as an option.
      # See Liquid::Profiler for more information
      def parse(source, options = {})
        environment = options[:environment] || Environment.default
        new(environment: environment).parse(source, options)
      end

      # Partially evaluates a template against variables known before it is
      # sent. See instance-level {#specialize} and {Liquid::Partial}.
      def preprocess(source, known_variables = {}, options = {})
        environment = options[:environment] || Environment.default
        parse(source, options).specialize(known_variables, options.merge(environment: environment))
      end
      alias_method :partial_evaluate, :preprocess
    end

    def initialize(environment: Environment.default)
      @environment = environment
      @rethrow_errors  = false
      @resource_limits = ResourceLimits.new(environment.default_resource_limits)
    end

    # Parse source code.
    # Returns self for easy chaining
    def parse(source, options = {})
      parse_context = configure_options(options)
      source = source.to_s.to_str

      unless source.valid_encoding?
        raise TemplateEncodingError, parse_context.locale.t("errors.syntax.invalid_template_encoding")
      end

      tokenizer     = parse_context.new_tokenizer(source, start_line_number: @line_numbers && 1)
      @root         = Document.parse(tokenizer, parse_context)
      self
    end

    def registers
      @registers ||= {}
    end

    def assigns
      @assigns ||= {}
    end

    def instance_assigns
      @instance_assigns ||= {}
    end

    def errors
      @errors ||= []
    end

    # Render takes a hash with local variables.
    #
    # if you use the same filters over and over again consider registering them globally
    # with <tt>Template.register_filter</tt>
    #
    # if profiling was enabled in <tt>Template#parse</tt> then the resulting profiling information
    # will be available via <tt>Template#profiler</tt>
    #
    # Following options can be passed:
    #
    #  * <tt>filters</tt> : array with local filters
    #  * <tt>registers</tt> : hash with register variables. Those can be accessed from
    #    filters and tags and might be useful to integrate liquid more with its host application
    #
    def render(*args)
      return '' if @root.nil?

      context = case args.first
      when Liquid::Context
        c = args.shift

        if @rethrow_errors
          c.exception_renderer = Liquid::RAISE_EXCEPTION_LAMBDA
        end

        c
      when Liquid::Drop
        drop = args.shift
        c    = Context.new([drop, assigns], instance_assigns, registers, @rethrow_errors, @resource_limits, {}, @environment)
        drop.context = c if drop.respond_to?(:context=)
        c
      when Hash
        Context.new([args.shift, assigns], instance_assigns, registers, @rethrow_errors, @resource_limits, {}, @environment)
      when nil
        Context.new(assigns, instance_assigns, registers, @rethrow_errors, @resource_limits, {}, @environment)
      else
        raise ArgumentError, "Expected Hash or Liquid::Context as parameter"
      end

      output = nil

      case args.last
      when Hash
        options = args.pop
        output  = options[:output] if options[:output]
        static_registers = context.registers.static

        options[:registers]&.each do |key, register|
          static_registers[key] = register
        end

        apply_options_to_context(context, options)
      when Module, Array
        context.add_filters(args.pop)
      end

      # Retrying a render resets resource usage
      context.resource_limits.reset

      if @profiling && context.profiler.nil?
        @profiler = context.profiler = Liquid::Profiler.new
      end

      context.template_name ||= name

      previous_error_mode = context.registers.static[:template_error_mode]
      context.registers.static[:template_error_mode] = @error_mode

      begin
        # render the nodelist.
        @root.render_to_output_buffer(context, output || +'')
      rescue Liquid::MemoryError => e
        context.handle_error(e)
      ensure
        if previous_error_mode
          context.registers.static[:template_error_mode] = previous_error_mode
        else
          context.registers.static.delete(:template_error_mode)
        end
        @errors = context.errors
      end
    end

    def render!(*args)
      @rethrow_errors = true
      render(*args)
    end

    # Partially evaluates this template against +known_variables+ and returns a
    # new Template (the residual template) that depends only on the remaining
    # variables.
    #
    # For every possible assignment of the remaining variables, the residual
    # template renders to the same output as the original and surfaces the
    # same errors. Only filters explicitly registered as pure on the
    # environment are executed during preprocessing; Drop methods, dynamic
    # +include+/+render+ and custom tags are never run.
    #
    # @param known_variables [Hash] variables whose values are already known,
    #   composed of plain hashes, arrays, strings, numbers, booleans and nil.
    # @option options [Liquid::PureFilterRegistry, Array<String, Symbol>] :pure_filters
    #   registry (or list of filter names) allowed at preprocessing time;
    #   defaults to the environment's registry.
    # @option options [Boolean] :strict_variables (false) whether undefined
    #   variables encountered while folding raise, matching the render option.
    # @option options [Integer] :max_unrolled_iterations (50) maximum number
    #   of iterations of a single known loop that are unrolled.
    # @return [Liquid::Template] the residual template. Its
    #   {#specialization_info} reports which expressions had to be retained.
    def specialize(known_variables = {}, options = {})
      environment = options[:environment] || @environment
      Partial.evaluate(self, known_variables, options.merge(environment: environment))
    end
    alias_method :preprocess, :specialize

    # @return [Array<Liquid::RetainedExpression>, nil] expressions that
    #   preprocessing could not eliminate, in template order.
    def retained_expressions
      @specialization_info&.retained_expressions
    end

    # @return [String, nil] approximate Liquid source of a specialized
    #   (residual) template. Intended for inspection and debugging only: the
    #   residual template renders from its specialized AST, not from this
    #   string. Returns nil for a template parsed normally.
    def residual_source
      return nil unless @root.is_a?(ResidualDocument)

      PartialSerializer.residual_nodelist(@root.nodes)
    end

    # @api private Used by {Liquid::Partial} to construct a residual template
    # from an already-built AST without re-parsing.
    def initialize_residual(document, environment, parse_context = nil)
      @environment = environment
      @root = document
      @resource_limits = ResourceLimits.new(environment.default_resource_limits)
      @rethrow_errors = false
      @options = parse_context&.instance_variable_get(:@template_options) || {}
      @error_mode = parse_context&.error_mode || environment.error_mode
      @warnings = parse_context ? parse_context.warnings : []
      self
    end

    def render_to_output_buffer(context, output)
      render(context, output: output)
    end

    private

    def configure_options(options)
      if (profiling = options[:profile])
        raise "Profiler not loaded, require 'liquid/profiler' first" unless defined?(Liquid::Profiler)
      end

      @options      = options
      @profiling    = profiling
      @line_numbers = options[:line_numbers] || @profiling
      parse_context = if options.is_a?(ParseContext)
        options
      else
        opts = options.key?(:environment) ? options : options.merge(environment: @environment)
        ParseContext.new(opts)
      end

      @warnings = parse_context.warnings
      @error_mode = parse_context.error_mode
      parse_context
    end

    def apply_options_to_context(context, options)
      context.add_filters(options[:filters]) if options[:filters]
      context.global_filter      = options[:global_filter] if options[:global_filter]
      context.exception_renderer = options[:exception_renderer] if options[:exception_renderer]
      context.strict_variables   = options[:strict_variables] if options[:strict_variables]
      context.strict_filters     = options[:strict_filters] if options[:strict_filters]
    end
  end
end
