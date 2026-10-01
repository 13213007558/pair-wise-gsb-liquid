# frozen_string_literal: true

module Liquid
  # Optional HTML-safe rendering mode.
  #
  # When enabled (via +Environment#html_safe+ or the +html_safe: true+ template
  # option), the template parser and the renderer jointly track the HTML
  # context the output is being written into, and every interpolation
  # (+{{ ... }}+, +{% echo %}+, +{% cycle %}+) is encoded according to that
  # context instead of being emitted as raw text.
  #
  # Supported HTML subset
  # ---------------------
  # The context tracker understands the following subset of HTML:
  #
  # * Text content between tags.
  # * Start tags, end tags and self-closing tags (names are matched
  #   case-insensitively).
  # * Attributes: double-quoted, single-quoted, unquoted, and valueless.
  # * HTML comments (+<!-- ... -->+) and bogus comments (+<!...>+, +<?...>+).
  # * Raw text elements: +<script>+ and +<style>+.
  #
  # Interpolation is handled as follows:
  #
  # * In text content the value is HTML-escaped (+&+, +<+, +>+).
  # * Inside a quoted or unquoted attribute value the value is escaped for
  #   that attribute form (+&+, +<+, +>+, both quote characters, and for
  #   unquoted values also whitespace, backtick and +=+).
  # * Inside a URL attribute (+href+, +src+, +action+, +formaction+, +poster+,
  #   +background+, +cite+, +data+, +xlink:href+) the scheme of the resulting
  #   value is validated against an allowlist (+http+, +https+, +mailto+,
  #   +tel+, plus relative URLs and fragments). Anything else, e.g.
  #   +javascript:+, +vbscript:+ or +data:+, is rejected with
  #   +Liquid::HTMLSafeError+.
  # * Interpolation inside event handler attributes (+on*+), inside
  #   +<script>+ / +<style>+ content, inside comments, or in any position the
  #   tracker cannot classify (e.g. between the attributes of a tag) is
  #   rejected with +Liquid::HTMLSafeError+.
  #
  # Context tracking crosses +{% if %}+ / +{% for %}+ branches and
  # +{% render %}+ partial boundaries at render time, because the tracker
  # lives in the shared static registers. +{% capture %}+ renders its body in
  # a fresh text context and marks the result as safe HTML, so captured
  # fragments are not escaped again when output in text content (they are
  # still escaped when output inside an attribute value).
  #
  # The mode is strictly opt-in; templates rendered without it behave exactly
  # as before.
  module HTMLSafe
    # Attributes whose values are interpreted as URLs by browsers.
    URL_ATTRIBUTES = %w[
      href src action formaction poster background cite data xlink:href
    ].freeze

    # Tags whose content is raw text (not escapable HTML).
    RAW_TEXT_TAGS = %w[script style].freeze

    # URL schemes considered safe for URL attributes.
    ALLOWED_URL_SCHEMES = %w[http https mailto tel].freeze

    # Only this many leading characters of an attribute value are kept for
    # URL scheme detection. Any dangerous scheme is far shorter than this.
    MAX_VALUE_PREFIX_LENGTH = 32

    TEXT_ESCAPE_MAP = {
      '&' => '&amp;',
      '<' => '&lt;',
      '>' => '&gt;',
    }.freeze
    TEXT_ESCAPE_REGEX = /[&<>]/

    ATTRIBUTE_ESCAPE_MAP = TEXT_ESCAPE_MAP.merge(
      '"' => '&quot;',
      "'" => '&#39;',
    ).freeze
    ATTRIBUTE_ESCAPE_REGEX = /[&<>"']/

    UNQUOTED_ATTRIBUTE_ESCAPE_MAP = ATTRIBUTE_ESCAPE_MAP.merge(
      ' ' => '&#32;',
      "\t" => '&#9;',
      "\n" => '&#10;',
      "\f" => '&#12;',
      "\r" => '&#13;',
      96.chr => '&#96;',
      '=' => '&#61;',
    ).freeze
    UNQUOTED_ATTRIBUTE_ESCAPE_REGEX = /[&<>"'\s\`=]/

    URL_SCHEME_REGEX = /\A([a-z][a-z0-9+.-]*):/
    URL_SCHEME_SEPARATOR_REGEX = %r{[:/?#]}
    URL_OBFUSCATION_REGEX = /[\x00-\x20]/

    # A string that is known to contain safe HTML (currently: the result of a
    # {% capture %} block rendered in HTML-safe mode). It is emitted verbatim
    # in text content and fully escaped inside attribute values.
    class SafeString < String
    end

    # Describes the HTML context an interpolation happens in.
    InterpolationContext = Struct.new(:type, :attribute_name, :quote, :value_prefix)

    TEXT_CONTEXT = InterpolationContext.new(:text).freeze

    # Incremental HTML context tracker. Literal template output is fed through
    # #track as it is parsed or rendered, and #context reports the context an
    # interpolation at the current position would land in.
    class Tracker
      TAG_NAME_REGEX = /\A[A-Za-z0-9-]+/
      ATTR_NAME_REGEX = /\A[^\s\/>="'<]+/
      UNQUOTED_VALUE_REGEX = /\A[^\s>]+/
      WHITESPACE = [" ", "\t", "\n", "\f", "\r"].freeze

      def initialize
        reset
      end

      def reset
        @state = :text
        @tag_name = nil
        @attr_name = nil
        @value_prefix = nil
        @rawtext_tag = nil
        @pending = +""
        @buffer = +""
      end

      def snapshot
        [@state, @tag_name, @attr_name, @value_prefix, @rawtext_tag, @pending, @buffer]
      end

      def restore(state)
        @state, @tag_name, @attr_name, @value_prefix, @rawtext_tag, @pending, @buffer = state
        @value_prefix = @value_prefix&.dup
        @pending = @pending.dup
        @buffer = @buffer.dup
      end

      def track(text)
        return if text.nil? || text.empty?

        @buffer << text
        consume!
        nil
      end

      def context
        case @state
        when :text
          TEXT_CONTEXT
        when :attr_double
          InterpolationContext.new(:attribute, @attr_name, :double, @value_prefix)
        when :attr_single
          InterpolationContext.new(:attribute, @attr_name, :single, @value_prefix)
        when :attr_unquoted
          InterpolationContext.new(:attribute, @attr_name, :unquoted, @value_prefix)
        when :before_value
          # an interpolation right after '=' starts an unquoted value
          InterpolationContext.new(:attribute, @attr_name, :unquoted, @value_prefix)
        when :rawtext
          InterpolationContext.new(:rawtext, @rawtext_tag)
        when :comment, :bogus_comment
          InterpolationContext.new(:comment)
        when :unknown
          InterpolationContext.new(:unknown)
        else
          # inside a tag, but not inside an attribute value
          InterpolationContext.new(:tag)
        end
      end

      # Records an interpolated value written into the current attribute
      # value, so URL scheme checks see the whole value.
      def append_value(str)
        accumulate_value(str)
      end

      private

      def consume!
        pos = 0
        buf = @buffer
        len = buf.length
        @waiting = false

        while pos < len && !@waiting
          pos = consume_step(buf, pos, len)
        end

        @buffer = buf[pos..] || +""
      end

      def consume_step(buf, pos, len)
        case @state
        when :text then consume_text(buf, pos, len)
        when :end_tag then consume_until_gt(buf, pos, len)
        when :bogus_comment then consume_until_gt(buf, pos, len)
        when :unknown then consume_until_gt(buf, pos, len)
        when :tag_name then consume_tag_name(buf, pos, len)
        when :tag then consume_tag(buf, pos, len)
        when :attr_name then consume_attr_name(buf, pos, len)
        when :after_attr_name then consume_after_attr_name(buf, pos)
        when :before_value then consume_before_value(buf, pos)
        when :attr_double then consume_quoted_value(buf, pos, len, '"')
        when :attr_single then consume_quoted_value(buf, pos, len, "'")
        when :attr_unquoted then consume_unquoted_value(buf, pos, len)
        when :comment then consume_comment(buf, pos, len)
        when :rawtext then consume_rawtext(buf, pos, len)
        else
          raise "unknown HTML tracker state: #{@state}"
        end
      end

      def consume_text(buf, pos, len)
        lt = buf.index('<', pos)
        return len unless lt

        if lt == len - 1
          @waiting = true
          return lt
        end

        case buf[lt + 1]
        when '!'
          rest = buf[lt + 2, 2]
          if rest.nil? || rest.empty? || rest == '-'
            # not enough input to tell a comment from a bogus comment
            @waiting = true
            lt
          elsif rest == '--'
            @state = :comment
            lt + 4
          else
            @state = :bogus_comment
            lt + 2
          end
        when '?'
          @state = :bogus_comment
          lt + 2
        when '/'
          @state = :end_tag
          lt + 2
        when /[A-Za-z]/
          @state = :tag_name
          @pending = +""
          lt + 1
        else
          # '<' is literal text
          lt + 2
        end
      end

      def consume_until_gt(buf, pos, len)
        if (gt = buf.index('>', pos))
          @state = :text
          gt + 1
        else
          len
        end
      end

      def consume_tag_name(buf, pos, len)
        if (match = buf[pos..].match(TAG_NAME_REGEX))
          @pending << match[0]
          pos += match[0].length
        end

        if pos < len
          @tag_name = @pending.downcase
          @pending = +""
          @state = :tag
        end
        pos
      end

      def consume_tag(buf, pos, len)
        case (ch = buf[pos])
        when *WHITESPACE
          pos + 1
        when '>'
          close_tag
          pos + 1
        when '/'
          if pos == len - 1
            @waiting = true
            pos
          elsif buf[pos + 1] == '>'
            close_tag
            pos + 2
          else
            pos + 1
          end
        when '"', "'", '=', '<'
          @state = :unknown
          pos + 1
        else
          @state = :attr_name
          @pending = +""
          pos
        end
      end

      def consume_attr_name(buf, pos, len)
        if (match = buf[pos..].match(ATTR_NAME_REGEX))
          @pending << match[0]
          pos += match[0].length
        end

        if pos < len
          @attr_name = @pending.downcase
          @pending = +""
          case buf[pos]
          when '='
            start_attribute_value
            @state = :before_value
            pos += 1
          when *WHITESPACE
            @state = :after_attr_name
            pos += 1
          else
            @state = :tag
          end
        end
        pos
      end

      def consume_after_attr_name(buf, pos)
        case buf[pos]
        when *WHITESPACE
          pos + 1
        when '='
          start_attribute_value
          @state = :before_value
          pos + 1
        else
          # attribute without a value
          @state = :tag
          pos
        end
      end

      def consume_before_value(buf, pos)
        case buf[pos]
        when *WHITESPACE
          pos + 1
        when '"'
          @state = :attr_double
          pos + 1
        when "'"
          @state = :attr_single
          pos + 1
        when '>'
          close_tag
          pos + 1
        else
          @state = :attr_unquoted
          pos
        end
      end

      def consume_quoted_value(buf, pos, len, quote)
        if (stop = buf.index(quote, pos))
          accumulate_value(buf[pos...stop])
          @state = :tag
          stop + 1
        else
          accumulate_value(buf[pos..])
          len
        end
      end

      def consume_unquoted_value(buf, pos, len)
        if (match = buf[pos..].match(UNQUOTED_VALUE_REGEX))
          accumulate_value(match[0])
          pos += match[0].length
        end

        if pos < len
          if buf[pos] == '>'
            close_tag
          else
            @state = :tag
          end
          pos += 1
        end
        pos
      end

      def consume_comment(buf, pos, len)
        if (stop = buf.index('-->', pos))
          @state = :text
          stop + 3
        else
          # keep the last two characters, they may start the '-->' delimiter
          @waiting = true
          [pos, len - 2].max
        end
      end

      def consume_rawtext(buf, pos, len)
        scan = pos
        while (idx = buf.index('</', scan))
          name_end = idx + 2 + @rawtext_tag.length
          if buf[idx + 2, @rawtext_tag.length]&.downcase == @rawtext_tag
            if name_end >= len
              # possibly an end tag; wait for the delimiter character
              @waiting = true
              return idx
            elsif WHITESPACE.include?(buf[name_end]) || buf[name_end] == '>' || buf[name_end] == '/'
              @state = :end_tag
              @rawtext_tag = nil
              return idx + 2
            end
          end
          scan = idx + 2
        end

        # keep a tail long enough to hold a partial end tag
        @waiting = true
        [pos, len - (@rawtext_tag.length + 1)].max
      end

      def close_tag
        if RAW_TEXT_TAGS.include?(@tag_name)
          # <script> and <style> are raw text elements; browsers ignore a
          # self-closing slash on them
          @state = :rawtext
          @rawtext_tag = @tag_name
        else
          @state = :text
        end
        @tag_name = nil
        @attr_name = nil
        @value_prefix = nil
      end

      def start_attribute_value
        @value_prefix = URL_ATTRIBUTES.include?(@attr_name) ? +"" : nil
      end

      def accumulate_value(str)
        return if @value_prefix.nil? || str.nil? || str.empty?

        remaining = MAX_VALUE_PREFIX_LENGTH - @value_prefix.length
        @value_prefix << str[0, remaining] if remaining.positive?
      end
    end

    class << self
      # The tracker for the current render, or nil when HTML-safe mode is off.
      def tracker(context)
        context.registers.static[:html_context_tracker]
      end

      # Records the parse-time HTML context of a variable and rejects
      # interpolations that are dangerous no matter what value they produce.
      # Partials are checked at render time instead, because their enclosing
      # context is not known while they are parsed.
      def annotate_variable(variable, parse_context)
        ctx = parse_context.html_tracker.context
        variable.html_context = ctx
        return if parse_context.partial

        case ctx.type
        when :text
          nil
        when :attribute
          if event_handler_attribute?(ctx.attribute_name)
            raise HTMLSafeError, "interpolation is not allowed inside the event handler " \
              "attribute #{ctx.attribute_name.inspect}"
          end
        else
          raise HTMLSafeError, "interpolation is not allowed #{describe_context(ctx)}"
        end
      end

      # Writes an interpolated value to the output, escaping it according to
      # the current HTML context or raising Liquid::HTMLSafeError when the
      # context does not allow interpolation.
      def write_value(tracker, output, obj)
        ctx = tracker.context
        case ctx.type
        when :text
          write_text_value(tracker, output, obj)
        when :attribute
          write_attribute_value(tracker, output, obj, ctx)
        else
          raise HTMLSafeError, "interpolation is not allowed #{describe_context(ctx)}"
        end
      end

      def escape_text(str)
        str.gsub(TEXT_ESCAPE_REGEX, TEXT_ESCAPE_MAP)
      end

      def escape_attribute(str, quote)
        if quote == :unquoted
          str.gsub(UNQUOTED_ATTRIBUTE_ESCAPE_REGEX, UNQUOTED_ATTRIBUTE_ESCAPE_MAP)
        else
          str.gsub(ATTRIBUTE_ESCAPE_REGEX, ATTRIBUTE_ESCAPE_MAP)
        end
      end

      private

      def write_text_value(tracker, output, obj)
        case obj
        when NilClass
          # nil interpolates to nothing
        when SafeString
          tracker.track(obj)
          output << obj
        when Array
          obj.each { |item| write_text_value(tracker, output, item) }
        else
          output << escape_text(Liquid::Utils.to_s(obj))
        end
      end

      def write_attribute_value(tracker, output, obj, ctx)
        name = ctx.attribute_name
        if event_handler_attribute?(name)
          raise HTMLSafeError, "interpolation is not allowed inside the event handler " \
            "attribute #{name.inspect}"
        end

        str = stringify(obj)
        check_url_scheme!(name, ctx.value_prefix, str) if URL_ATTRIBUTES.include?(name)
        output << escape_attribute(str, ctx.quote)
        tracker.append_value(str)
      end

      def stringify(obj)
        case obj
        when NilClass
          +""
        when Array
          obj.map { |item| Liquid::Utils.to_s(item) }.join
        else
          Liquid::Utils.to_s(obj)
        end
      end

      def check_url_scheme!(attribute_name, prefix, value)
        return if prefix&.match?(URL_SCHEME_SEPARATOR_REGEX)

        candidate = +""
        candidate << prefix if prefix
        candidate << value
        # browsers ignore C0 controls and whitespace inside the scheme
        scheme = candidate.gsub(URL_OBFUSCATION_REGEX, "").downcase[URL_SCHEME_REGEX, 1]
        return if scheme.nil? || ALLOWED_URL_SCHEMES.include?(scheme)

        raise HTMLSafeError, "unsafe URL scheme #{scheme.inspect} in #{attribute_name.inspect} attribute"
      end

      def event_handler_attribute?(name)
        name.start_with?("on")
      end

      def describe_context(ctx)
        case ctx.type
        when :rawtext then "inside <#{ctx.attribute_name}> content"
        when :comment then "inside an HTML comment"
        when :tag then "inside a tag (outside of an attribute value)"
        else "in an unrecognized HTML context"
        end
      end
    end
  end
end
