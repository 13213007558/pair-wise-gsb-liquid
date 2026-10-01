# frozen_string_literal: true

require 'set'

module Liquid
  # StrainerTemplate is the computed class for the filters system.
  # New filters are mixed into the strainer class which is then instantiated for each liquid template render run.
  #
  # The Strainer only allows method calls defined in filters given to it via StrainerFactory.add_global_filter,
  # Context#add_filters or Template.register_filter
  class StrainerTemplate
    # Filter safety categories understood by the opt-in HTML auto-escaping mode:
    #
    # :escape        - output is HTML escaped, safe as body text and in quoted
    #                  attributes (idempotent on already safe input)
    # :url           - output is percent encoded, safe anywhere including URLs
    # :html_markup   - filter emits HTML markup derived from a safe input
    # :preserve      - output retains the safety category of its input
    # :preserve_args - like :preserve, but only when every other string
    #                  argument is itself trusted
    SAFE_FILTER_CATEGORIES = [:escape, :url, :html_markup, :preserve, :preserve_args].freeze

    def initialize(context)
      @context = context
    end

    class << self
      def add_filter(filter)
        return if include?(filter)

        invokable_non_public_methods = (filter.private_instance_methods + filter.protected_instance_methods).select { |m| invokable?(m) }
        if invokable_non_public_methods.any?
          raise MethodOverrideError, "Filter overrides registered public methods as non public: #{invokable_non_public_methods.join(', ')}"
        end

        include(filter)

        filter_methods.merge(filter.public_instance_methods.map(&:to_s))
      end

      def invokable?(method)
        filter_methods.include?(method.to_s)
      end

      # Declares how filter outputs are to be trusted when HTML auto-escaping is
      # enabled. Filters without a declaration produce untrusted output and are
      # escaped again if rendered.
      #
      #   StrainerTemplate.safe_filter :escape, :escape
      #   StrainerTemplate.safe_filter :upcase, :preserve
      def safe_filter(method, category)
        unless SAFE_FILTER_CATEGORIES.include?(category)
          raise ArgumentError, "unknown safe filter category #{category.inspect}"
        end

        safe_filter_methods[method.to_s] = category
      end

      def safe_filter_category(method)
        name = method.to_s
        # Walk the ancestor chain so a declaration registered on a parent
        # (e.g. a filter marked safe after the environment built a cached
        # subclass) is still visible. A subclass may shadow with its own entry.
        klass = self
        while klass <= StrainerTemplate
          methods = klass.instance_variable_get(:@safe_filter_methods)
          return methods[name] if methods&.key?(name)

          klass = klass.superclass
        end
        nil
      end

      def inherited(subclass)
        super
        subclass.instance_variable_set(:@filter_methods, @filter_methods.dup)
        subclass.instance_variable_set(:@safe_filter_methods, @safe_filter_methods.dup)
      end

      def filter_method_names
        filter_methods.map(&:to_s).to_a
      end

      private

      def filter_methods
        @filter_methods ||= Set.new
      end

      def safe_filter_methods
        @safe_filter_methods ||= {}
      end
    end

    def invoke(method, *args)
      if self.class.invokable?(method)
        result = send(method, *args)
        label_result(method, args, result)
      elsif @context.strict_filters
        raise Liquid::UndefinedFilter, "undefined filter #{method}"
      else
        # An unknown filter is a no-op in lax mode, so its input passes through
        # unchanged (preserving any safety category it already carried).
        args.first
      end
    rescue ::ArgumentError => e
      raise Liquid::ArgumentError, e.message, e.backtrace
    end

    private

    # Labels a filter result with an auto-escape safety category when
    # auto-escaping is active. Without it (the default render behaviour) values
    # pass through untouched.
    def label_result(method, args, result)
      return result unless @context&.html_autoescape?
      return result unless result.is_a?(String)

      category = self.class.safe_filter_category(method)
      case category
      when nil
        # An unknown/undeclared filter might have produced markup from user
        # data: drop any trust the input carried.
        demote(result)
      when :escape
        # Idempotent: an already escaped/safe value passes through unchanged.
        result.is_a?(SafeString) ? result : SafeString.new(result, :attribute)
      when :url
        SafeString.new(result, :url)
      when :html_markup
        SafeString.new(result, :html)
      when :preserve
        preserve_category(args.first, result)
      when :preserve_args
        if args.all? { |arg| trusted_or_non_string?(arg) }
          preserve_category(args.first, result)
        else
          demote(result)
        end
      else
        demote(result)
      end
    end

    def preserve_category(input, result)
      if input.is_a?(SafeString)
        SafeString.new(result, input.safe_category)
      else
        demote(result)
      end
    end

    def trusted_or_non_string?(arg)
      !arg.is_a?(String) || arg.is_a?(SafeString)
    end

    def demote(result)
      result.is_a?(SafeString) ? result.to_unsafe_string : result
    end
  end
end
