# frozen_string_literal: true

require 'cgi'
require 'strscan'

module Liquid
  class HtmlSafety
    SafeFragment = Class.new(String)

    URL_ATTRIBUTES = %w[
      action
      background
      cite
      formaction
      href
      longdesc
      manifest
      poster
      src
      srcset
      xlink:href
    ].freeze
    private_constant :URL_ATTRIBUTES

    RAW_ELEMENTS = { 'script' => 'script', 'style' => 'style' }.freeze
    private_constant :RAW_ELEMENTS

    UNSAFE_INTERPOLATION_MESSAGE = "interpolation is not allowed in this HTML context"
    UNSUPPORTED_UNQUOTED_ATTRIBUTE_MESSAGE = "unquoted HTML attributes are not supported in HTML safe rendering"
    UNSAFE_URL_MESSAGE = "unsafe URL scheme in HTML attribute"
    INCOMPATIBLE_CAPTURE_MESSAGE = "capture blocks must end in HTML text context"

    attr_reader :state

    def initialize
      reset
      @capture_stack = []
    end

    def append_static(output, literal)
      literal = literal.to_s
      scan_static(literal)
      output << literal
    end

    def append_interpolation(output, value, html_escaped: false)
      if html_safe_fragment?(value)
        raise HtmlSafetyError, UNSAFE_INTERPOLATION_MESSAGE unless @state == :content
        value = value.to_s
      else
        validate_url_buffer if @state == :url_attribute
        value = render_value(value, html_escaped: html_escaped)
      end
      output << value
    end

    def begin_capture
      @capture_stack << [
        @state, @tag_name, @attribute_name, @quote, @url_attribute, @url_buffer,
      ]
      reset
    end

    def end_capture(output)
      valid_capture = @state == :content
      restore_capture
      raise HtmlSafetyError, INCOMPATIBLE_CAPTURE_MESSAGE unless valid_capture

      SafeFragment.new(output.to_s)
    end

    def abort_capture
      restore_capture
    end

    private

    def reset
      @state = :content
      @tag_name = +''
      @attribute_name = +''
      @quote = nil
      @url_attribute = false
      @url_buffer = nil
    end

    def restore_capture
      @state, @tag_name, @attribute_name, @quote, @url_attribute, @url_buffer = @capture_stack.pop
    end

    def scan_static(literal)
      scanner = StringScanner.new(literal)

      until scanner.eos?
        case @state
        when :content then scan_content(scanner)
        when :tag_open then scan_tag_open(scanner)
        when :tag_name then scan_tag_name(scanner)
        when :end_tag then scan_end_tag(scanner)
        when :after_tag_name then scan_after_tag_name(scanner)
        when :before_attributes then scan_before_attributes(scanner)
        when :attribute_name then scan_attribute_name(scanner)
        when :after_attribute_name then scan_after_attribute_name(scanner)
        when :before_attribute_value then scan_before_attribute_value(scanner)
        when :quoted_attribute then scan_quoted_attribute(scanner)
        when :url_attribute then scan_url_attribute(scanner)
        when :dangerous_attribute then scan_dangerous_attribute(scanner)
        when :raw_text then scan_raw_text(scanner)
        when :comment then scan_comment(scanner)
        when :cdata then scan_cdata(scanner)
        when :declaration, :tag_bang then scan_declaration(scanner)
        end
      end
    end

    def scan_content(scanner)
      unless scanner.match?(/</)
        scanner.terminate
        return
      end
      return if scanner.eos?

      scanner.getch
      @state = :tag_open
    end

    def scan_tag_open(scanner)
      char = scanner.getch
      return if char.nil?

      case char
      when /[A-Za-z]/
        @tag_name = char.downcase
        @state = :tag_name
      when '/'
        @state = :end_tag
      when '!'
        scan_tag_bang(scanner)
      when '?'
        @state = :declaration
      when '<'
        scanner.pos -= 1
      else
        scanner.pos -= 1
        @state = :content
      end
    end

    def scan_tag_bang(scanner)
      if scanner.scan(/--/)
        @state = :comment
      elsif scanner.scan(/\[CDATA\[/)
        @state = :cdata
      else
        @state = :declaration
      end
    end

    def scan_tag_name(scanner)
      @tag_name << scanner.scan(/[A-Za-z0-9:_-]+/).to_s.downcase
      @state = :after_tag_name
    end

    def scan_end_tag(scanner)
      scanner.scan(/[A-Za-z0-9:_-]+/)
      scanner.skip(/\s*/)
      finish_tag(scanner)
    end

    def scan_after_tag_name(scanner)
      if scanner.scan(/\s+/)
        @state = :before_attributes
      elsif scanner.scan(%r{/\s*>}) || scanner.match?('>')
        finish_tag(scanner)
      else
        @state = :attribute_name
      end
    end

    def scan_before_attributes(scanner)
      if scanner.scan(/\s+/)
        # Continue after whitespace.
      elsif scanner.scan(%r{/})
        @state = :after_tag_name
      elsif scanner.match?('>')
        finish_tag(scanner)
      elsif scanner.eos?
        return
      else
        @state = :attribute_name
      end
    end

    def start_attribute(scanner)
      @attribute_name = scanner.scan(/[A-Za-z0-9:_.-]+/).to_s.downcase
      @state = :after_attribute_name
    end

    def scan_attribute_name(scanner)
      start_attribute(scanner)
    end

    def scan_after_attribute_name(scanner)
      if scanner.scan(/\s+/)
        # Continue after whitespace.
      elsif scanner.scan(/=/)
        @state = :before_attribute_value
      elsif scanner.scan(%r{/})
        @state = :after_tag_name
      elsif scanner.match?('>')
        finish_tag(scanner)
      elsif scanner.match?(/[A-Za-z_:]/)
        @state = :attribute_name
      else
        scanner.getch
        @state = :before_attributes
      end
    end

    def scan_before_attribute_value(scanner)
      if scanner.scan(/\s+/)
        # Continue after whitespace.
        return
      end

      quote = scanner.scan(/["']/)
      unless quote
        raise HtmlSafetyError, UNSUPPORTED_UNQUOTED_ATTRIBUTE_MESSAGE
      end

      @quote = quote
      @url_attribute = URL_ATTRIBUTES.include?(@attribute_name)

      if @url_attribute
        @url_buffer = +''
        @state = :url_attribute
      elsif dangerous_attribute?(@attribute_name)
        @state = :dangerous_attribute
      else
        @state = :quoted_attribute
      end
    end

    def scan_quoted_attribute(scanner)
      scanner.skip_until(/#{Regexp.escape(@quote)}/) || scanner.terminate
      finish_attribute if scanner.matched?
    end

    def scan_url_attribute(scanner)
      chunk = scanner.scan_until(/#{Regexp.escape(@quote)}/)
      if chunk.nil? || !scanner.matched?
        @url_buffer << scanner.rest
        scanner.terminate
        return
      end

      @url_buffer << chunk[0...-1]
      validate_url_buffer
      finish_attribute
    end

    def scan_dangerous_attribute(scanner)
      scanner.skip_until(/#{Regexp.escape(@quote)}/) || scanner.terminate
      finish_attribute if scanner.matched?
    end

    def scan_raw_text(scanner)
      raw_tag = RAW_ELEMENTS.fetch(@tag_name)
      scanner.skip_until(%r{</#{raw_tag}\s*>}i) || scanner.terminate
      @state = :content if scanner.matched?
    end

    def scan_comment(scanner)
      scanner.skip_until(/-->/) || scanner.terminate
      @state = :content if scanner.matched?
    end

    def scan_cdata(scanner)
      scanner.skip_until(/\]\]>/) || scanner.terminate
      @state = :content if scanner.matched?
    end

    def scan_declaration(scanner)
      scanner.skip_until(/>/) || scanner.terminate
      @state = :content if scanner.matched?
    end

    def finish_attribute
      @quote = nil
      @url_attribute = false
      @url_buffer = nil
      @state = :before_attributes
    end

    def finish_tag(scanner)
      scanner.skip(/>/) || raise(HtmlSafetyError, UNSAFE_INTERPOLATION_MESSAGE)
      @state = RAW_ELEMENTS.key?(@tag_name) ? :raw_text : :content
    end

    def dangerous_attribute?(name)
      name.start_with?('on') || name == 'style' || name == 'srcdoc'
    end

    def render_value(value, html_escaped:)
      case value
      when nil
        +''
      when Array
        value.map { |item| render_value(item, html_escaped: html_escaped) }.join
      else
        render_scalar(Liquid::Utils.to_s(value), html_escaped: html_escaped)
      end
    end

    def render_scalar(value, html_escaped:)
      case @state
      when :content
        html_escaped ? value : CGI.escapeHTML(value)
      when :quoted_attribute
        html_escaped ? value : CGI.escapeHTML(value)
      when :url_attribute
        render_url_value(value)
      else
        raise HtmlSafetyError, UNSAFE_INTERPOLATION_MESSAGE
      end
    end

    def validate_url_buffer
      unless safe_url?(@url_buffer)
        raise HtmlSafetyError, UNSAFE_URL_MESSAGE
      end
    end

    def render_url_value(value)
      escaped = if @attribute_name == 'srcset'
        value.split(',').map { |candidate| render_srcset_candidate(candidate) }.join(',')
      elsif safe_url?(value)
        CGI.escapeHTML(escape_preserved_url(value))
      else
        CGI.escapeHTML(CGI.escape(value))
      end
      @url_buffer << escaped
      escaped
    end

    def render_srcset_candidate(candidate)
      url, descriptor = candidate.split(/\s+/, 2)
      escaped_url = safe_url?(url) ? escape_preserved_url(url) : CGI.escape(url)
      escaped_descriptor = descriptor ? " #{CGI.escape(descriptor).gsub('+', '%20')}" : ''
      escaped_url + escaped_descriptor
    end

    def escape_preserved_url(url)
      CGI.escape(url)
        .gsub('+', '%20')
        .gsub('%2F', '/')
        .gsub('%3A', ':')
        .gsub('%3F', '?')
        .gsub('%3D', '=')
        .gsub('%26', '&')
        .gsub('%3B', ';')
    end

    def safe_url?(url)
      decoded = CGI.unescapeHTML(url.to_s).gsub(/[\t\n\f\r ]/, '')
      return false if decoded.match?(/[\x00-\x1F\x7F]/)
      return true if decoded.empty? || decoded.start_with?('/', '#', '?', '.')

      match = decoded.match(/\A([A-Za-z][A-Za-z0-9+.-]*):/)
      match.nil? || %w[http https].include?(match[1].downcase)
    end

    def html_safe_fragment?(value)
      value.is_a?(SafeFragment) || (value.respond_to?(:html_safe?) && value.html_safe?)
    end
  end
end
