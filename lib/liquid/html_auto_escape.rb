# frozen_string_literal: true

module Liquid
  # Opt-in, context aware HTML auto-escaping.
  #
  # When a template is parsed (or rendered) with +autoescape: true+, every
  # dynamic value is escaped according to the position of its output tag in the
  # surrounding HTML document:
  #
  #   <p>{{ value }}</p>                      -> body text escaping
  #   <a title="{{ value }}">...</a>         -> quoted attribute escaping
  #   <a href="{{ value }}">...</a>          -> URL filtering + attribute escaping
  #
  # Positions where no safe escaping transform exists reject dynamic values
  # rather than guessing one:
  #
  #   <script>{{ value }}</script>           -> Liquid::AutoEscapeError
  #   <style>{{ value }}</style>             -> Liquid::AutoEscapeError
  #   <a href={{ value }}>                   -> unquoted, rejected
  #   <{{ value }}> / <!-- {{ value }} -->   -> rejected
  #
  # Values that have already been made safe (e.g. by the +escape+ filter or a
  # +capture+ that produced body-safe content) carry a {Liquid::SafeString}
  # category, so they are never escaped twice.
  module HtmlAutoEscape
    # Attributes whose values are interpreted as URLs.
    URL_ATTRIBUTES = %w[
      action
      cite
      data
      formaction
      href
      icon
      manifest
      poster
      src
      xlink:href
    ].each_with_object({}) { |name, hash| hash[name] = true }.freeze

    # Raw text elements: their content is character data in a non-HTML
    # language, so HTML escaping cannot make dynamic values safe there.
    RAWTEXT_ELEMENTS = { 'script' => true, 'style' => true }.freeze

    # Escapes needed for body text: & < > are sufficient to keep dynamic text
    # from being parsed as markup.
    BODY_ESCAPE = {
      '&' => '&amp;',
      '<' => '&lt;',
      '>' => '&gt;',
    }.freeze

    # Escapes needed inside a quoted attribute value: quote characters are
    # significant in addition to the body escapes.
    ATTRIBUTE_ESCAPE = BODY_ESCAPE.merge(
      '"' => '&quot;',
      "'" => '&#39;',
      '`' => '&#96;',
    ).freeze

    # URI schemes allowed through URL filtering. Relative URLs (including
    # protocol-relative, fragment-only and query-only) are always allowed.
    SAFE_URL_SCHEMES = %w[http https ftp mailto tel].freeze

    # Bytes allowed to appear literally in a filtered URL. Everything else
    # (including quote and markup characters, spaces, ampersands and
    # backslashes) is percent-encoded so a value can never break out of a
    # quoted attribute.
    ALLOWED_URL_BYTES = (
      ('a'..'z').to_a + ('A'..'Z').to_a + ('0'..'9').to_a +
      %w[- . _ ~ : / ? # [ ] @ ! $ ( ) * + , ; = %]
    ).each_with_object({}) { |byte, hash| hash[byte] = true }.freeze

    def self.escape_body(str)
      str.gsub(/[&<>]/) { |char| BODY_ESCAPE.fetch(char) }
    end

    def self.escape_attribute(str)
      str.gsub(/[&<>"'`]/) { |char| ATTRIBUTE_ESCAPE.fetch(char) }
    end

    # Filters a dynamic URL so that it can safely be used as the value of a
    # URL-typed attribute. Dangerous schemes (javascript:, data:, vbscript:,
    # ...) are rejected; the value is also percent-encoded as needed.
    def self.sanitize_url(url)
      url = Liquid::Utils.to_s(url)

      # Browsers decode HTML entities in attribute values before URL parsing,
      # so detect schemes on the entity-decoded form while emitting an encoded
      # form of the original value below.
      compacted = decode_entities_for_scheme_check(url).gsub(/[\x00-\x20\x7F]/, '')
      if (match = /\A[a-zA-Z][a-zA-Z0-9+\-.]*:/.match(compacted))
        scheme = match[0].chomp(':').downcase
        unless SAFE_URL_SCHEMES.include?(scheme)
          raise UnsafeUrlError, "unsafe URL protocol #{scheme}: is not permitted in a URL attribute"
        end
      end

      encoded = +''
      url.each_char do |char|
        if char.ascii_only? && ALLOWED_URL_BYTES.key?(char)
          encoded << char
        else
          char.each_byte { |byte| encoded << format('%%%02X', byte) }
        end
      end
      encoded
    end

    # Decodes numeric and the most common whitespace/colon entities used to
    # disguise a scheme (e.g. "javascript&#58;alert(1)" or "java&#x09;script:").
    def self.decode_entities_for_scheme_check(str)
      str.gsub(/&#(\d+);?|&#x([0-9a-fA-F]+);?|&(colon|tab|newline);/) do
        if (digits = Regexp.last_match(1))
          decode_codepoint(digits.to_i)
        elsif (hex = Regexp.last_match(2))
          decode_codepoint(hex.to_i(16))
        else
          case Regexp.last_match(3)
          when 'colon' then ':'
          when 'tab', 'newline' then ''
          else Regexp.last_match(0)
          end
        end
      end
    end

    def self.decode_codepoint(codepoint)
      codepoint.chr(Encoding::UTF_8)
    rescue RangeError
      ''
    end

    # Tracks the HTML parsing state as raw template text streams past during
    # rendering. One instance is used per rendered document; inline fragments
    # (rendered partials, captures) temporarily swap in a seeded state.
    class State
      attr_reader :state, :attr_name, :is_url_attr, :rawtext_tag

      def initialize
        reset
      end

      def reset
        @state = :text
        @tag_name = nil
        @attr_name = nil
        @is_url_attr = false
        @rawtext_tag = nil
        @rawtext_phase = nil
        @rawtext_match = +''
        self
      end

      # Feeds raw template text and advances the HTML state machine.
      def feed(text)
        return self if text.nil? || text.empty?

        text.each_char { |char| consume(char) }
        self
      end

      # Escapes or validates a dynamic value for the position the output tag is
      # currently in and returns the string that is safe to emit. The value is
      # treated as an atomic interpolation: the state advances as if the value
      # (which is escaped for the context) were a single safe token.
      def emit(obj)
        category = interpolation_category
        rendered = emit_for_category(obj, category)
        consume_interpolation
        rendered
      end

      def emit_for_category(obj, category)
        return '' if obj.nil?

        case obj
        when SafeString
          emit_safe(obj, category)
        when Array
          obj.map { |item| emit_for_category(item, category) }.join
        else
          emit_unsafe(Liquid::Utils.to_s(obj), category)
        end
      end

      # Advances the state past one atomic, context-safe interpolation.
      #
      # Escaped content cannot contain the delimiter of its context, so the
      # state simply *stays* where it is: inside a quoted attribute the
      # following closing quote is static template text and ends the value;
      # in text/raw text the context is unchanged. This avoids treating the
      # closing quote as a new tag and makes captures inside values work.
      def consume_interpolation
        # no state change: the emitted value is inert for the HTML parser
      end

      # Builds a fresh state for an inline fragment (a rendered partial)
      # starting in the given interpolation category. Attribute fragments
      # start inside the value because their opening quote was already
      # consumed by the parent template.
      def self.seeded_for(category)
        state = new
        if category == :attribute || category == :url
          state.instance_variable_set(:@state, :attr_dq)
          state.instance_variable_set(:@is_url_attr, category == :url)
        end
        state
      end

      # The escaping category an untrusted value receives at the current
      # position; raises Liquid::AutoEscapeError when interpolation is
      # forbidden here.
      def interpolation_category
        case @state
        when :text
          :html
        when :attr_dq, :attr_sq
          @is_url_attr ? :url : :attribute
        when :before_value, :attr_unquoted
          raise AutoEscapeError,
            "dynamic values are not allowed in unquoted HTML attributes; add quotes around the attribute value"
        when :rawtext
          raise AutoEscapeError,
            "dynamic values are not allowed inside <#{@rawtext_tag}> elements, whose content is not HTML"
        when :comment
          raise AutoEscapeError, "dynamic values are not allowed inside HTML comments"
        when :declaration
          raise AutoEscapeError, "dynamic values are not allowed inside HTML declarations or processing instructions"
        else
          raise AutoEscapeError, "dynamic values are not allowed in HTML tag or attribute names"
        end
      end

      # Capture tags occupy an interpolation position even though they emit
      # nothing themselves: this validates the position (raising when dynamic
      # content is forbidden there) and returns the category for the fragment.
      def capture_interpolation_category
        interpolation_category
      end

      private

      def emit_safe(safe, category)
        target = category == :url ? :url : category

        if safe.safe_for?(target)
          safe.to_s
        else
          raise AutoEscapeError,
            "a value prepared for #{safe.safe_category} context cannot be inserted into #{target} context"
        end
      end

      def emit_unsafe(str, category)
        case category
        when :html
          HtmlAutoEscape.escape_body(str)
        when :attribute
          HtmlAutoEscape.escape_attribute(str)
        when :url
          HtmlAutoEscape.sanitize_url(str)
        end
      end

      # A hand-written HTML-ish tokenizer, precise enough to locate the
      # interpolation contexts the auto-escaper cares about.
      def consume(char)
        case @state
        when :text
          @state = :lt if char == '<'
        when :lt
          consume_after_lt(char)
        when :tag_name
          consume_tag_name(char)
        when :close_tag
          if char == '>'
            @state = :text
          elsif char =~ /\s/
            @state = :close_tag_space
          end
        when :close_tag_space
          @state = :text if char == '>'
        when :declaration_start
          case char
          when '-' then @state = :declaration_dash1
          when '>' then @state = :text
          else @state = :declaration
          end
        when :declaration_dash1
          @state = char == '-' ? :comment_dash1 : :declaration
        when :comment_dash1
          case char
          when '-' then @state = :comment_dash2
          when '>' then @state = :text # bogus short comment
          else @state = :comment
          end
        when :comment
          @state = :comment_dash1 if char == '-'
        when :comment_dash1
          @state = char == '-' ? :comment_dash2 : :comment
        when :comment_dash2
          if char == '>'
            @state = :text
          elsif char != '-'
            @state = :comment
          end
        when :declaration
          @state = :text if char == '>'
        when :tag_space, :tag_self_closing
          consume_tag_space(char)
        when :attr_name
          consume_attr_name(char)
        when :after_attr_name
          consume_after_attr_name(char)
        when :before_value
          consume_before_value(char)
        when :attr_dq
          finish_attribute if char == '"'
        when :attr_sq
          finish_attribute if char == "'"
        when :attr_unquoted
          if char == '>'
            enter_text
          elsif char =~ /\s/
            @state = :tag_space
          end
        when :rawtext
          consume_rawtext(char)
        end
      end

      def consume_after_lt(char)
        case char
        when '/'
          @state = :close_tag
        when '!'
          @state = :declaration_start
        when /\s/
          @state = :text
        else
          @tag_name = char.downcase
          @state = :tag_name
        end
      end

      def consume_tag_name(char)
        case char
        when '>'
          enter_text
        when '/'
          @state = :tag_self_closing
        when /\s/
          @state = :tag_space
        else
          @tag_name << char.downcase
        end
      end

      def consume_tag_space(char)
        case char
        when '>'
          enter_text
        when '/'
          @state = :tag_self_closing
        when /\S/
          @attr_name = char.downcase
          @state = :attr_name
        end
      end

      def consume_attr_name(char)
        case char
        when '>'
          enter_text
        when '/'
          @state = :tag_self_closing
        when /\s/
          @state = :after_attr_name
        when '='
          @is_url_attr = URL_ATTRIBUTES.key?(@attr_name)
          @state = :before_value
        else
          @attr_name << char.downcase
        end
      end

      def consume_after_attr_name(char)
        case char
        when '>'
          enter_text
        when '='
          @is_url_attr = URL_ATTRIBUTES.key?(@attr_name)
          @state = :before_value
        when '/'
          @state = :tag_self_closing
        when /\S/
          @attr_name = char.downcase
          @state = :attr_name
        end
      end

      def consume_before_value(char)
        case char
        when '"'
          @state = :attr_dq
        when "'"
          @state = :attr_sq
        when '>'
          enter_text
        when /\s/
          # leading whitespace before the value, still in :before_value
        else
          # Unquoted attribute value; interpolation there is rejected at emit
          # time, but static text is still tracked.
          @state = :attr_unquoted
          consume(char)
        end
      end

      def consume_rawtext(char)
        tag = @rawtext_tag
        case @rawtext_phase
        when nil
          @rawtext_phase = :lt if char == '<'
        when :lt
          if char == '/'
            @rawtext_phase = :slash
          else
            @rawtext_phase = nil
          end
        when :slash
          if char == tag[0]
            @rawtext_match = char
            @rawtext_phase = :name
          else
            @rawtext_phase = nil
          end
        when :name
          expected = tag[@rawtext_match.length]
          if expected && char == expected
            @rawtext_match << char
            if @rawtext_match == tag
              @rawtext_phase = :terminator
            end
          else
            @rawtext_phase = nil
          end
        when :terminator
          case char
          when '>'
            enter_text
          when /[\s\/]/
            # tolerate whitespace or a self-closing slash before '>'
          else
            @rawtext_phase = nil
          end
        end
      end

      def finish_attribute
        @is_url_attr = false
        @attr_name = nil
        @state = :tag_space
      end

      def enter_text
        if RAWTEXT_ELEMENTS.key?(@tag_name)
          @rawtext_tag = @tag_name
          @rawtext_phase = nil
          @rawtext_match = +''
          @state = :rawtext
        else
          @state = :text
        end
        @tag_name = nil
        @attr_name = nil
        @is_url_attr = false
      end
    end
  end
end
