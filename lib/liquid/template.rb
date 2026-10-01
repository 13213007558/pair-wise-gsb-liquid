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

    # Partially evaluates this parsed template against +known_data+ that is
    # identical for every subsequent rendering, and returns a new Template that
    # still accepts the remaining, dynamic variables.
    #
    #   template    = Liquid::Template.parse(source)
    #   specialized = template.specialize(
    #     { 'tenant' => 'Acme', 'config' => config },
    #     pure_filters: [:upcase, MyPureFilters],
    #   )
    #   specialized.render('order' => order)
    #
    # Fixed text, fixed variables and conditions that are decidable from
    # +known_data+ are folded. Conditions that depend on unknown variables,
    # loops and variable shadowing are preserved with their original
    # semantics.
    #
    # +known_data+ must contain only plain values (nil, booleans, numbers,
    # strings, symbols and arrays/hashes thereof). Liquid::Drop values and
    # Procs are rejected.
    #
    # +pure_filters+ is the explicit list of filters that are guaranteed to be
    # pure (deterministic and side-effect free). Each entry is either a filter
    # name (String or Symbol) or a Module whose public instance methods are all
    # treated as pure. Only these filters are ever invoked during
    # specialization; every other filter is deferred to render time. Filters
    # supplied as Modules are also made available to the resulting template
    # unless they are already registered on the environment.
    #
    # Options:
    # * <tt>:filters</tt> : array of filter Modules that the declared pure
    #   filter names may refer to (also available at render time)
    #
    # The returned template is semantically equivalent to the original for any
    # dynamic input: output, error locations, filter side-effect counts and
    # resource limit consumption match.
    def specialize(known_data = nil, **options)
      # Ruby turns a trailing String-keyed hash literal into keyword arguments
      # for a method that also accepts keywords (option keys are Symbols).
      # Recover such data and keep only the Symbol option keys.
      if known_data.nil? && options.keys.any? { |key| key.is_a?(String) }
        known_data = options.select { |key, _value| key.is_a?(String) }
        options.select! { |key, _value| key.is_a?(Symbol) }
      end

      known_data = {} if known_data.nil?
      unless known_data.is_a?(Hash)
        raise ArgumentError, "specialize expects a Hash of known data, got #{known_data.class}"
      end

      pure_filters = options.fetch(:pure_filters, [])
      filters = options.fetch(:filters, [])

      extra_modules = []

      pure_filter_names = Array(pure_filters).each_with_object(Set.new) do |entry, names|
        case entry
        when Symbol, String
          names << entry.to_s
        when Module
          entry.public_instance_methods.each { |name| names << name.to_s }
          extra_modules << entry
        else
          raise ArgumentError,
            "pure_filters entries must be filter names or modules: #{entry.inspect}"
        end
      end

      Array(filters).each do |mod|
        raise ArgumentError, "filters entries must be modules: #{mod.inspect}" unless mod.is_a?(Module)
        extra_modules << mod
      end

      Specializer.new(self, known_data,
        pure_filter_names: pure_filter_names,
        extra_filter_modules: extra_modules.uniq).specialize
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
