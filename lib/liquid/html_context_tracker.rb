# frozen_string_literal: true

module Liquid
  # Best-effort static analysis of the HTML context in which {{ }} outputs
  # appear, used by the opt-in HTML autoescape mode.
  #
  # The tracker is fed the raw (static) text of a template as it is parsed
  # and can then tell, for each output position, whether it falls in:
  #
  #   :text          - HTML element content
  #   :attr          - inside a quoted attribute value
  #   :url           - inside a quoted value of a URL attribute (href, src, ...)
  #
  # Positions where no correct escaping exists are reported as forbidden
  # instead of guessing an escaping strategy:
  #
  #   :script        - inside a <script> element
  #   :style         - inside a <style> element
  #   :script_attr   - inside an event handler attribute (onclick, ...)
  #   :style_attr    - inside a style attribute
  #   :unquoted_attr - inside a tag but outside a quoted attribute value
  class HtmlContextTracker
    URL_ATTRIBUTES = [
      "href", "src", "action", "formaction", "poster",
      "background", "cite", "longdesc", "xlink:href",
    ].freeze

    RAW_TEXT_ELEMENTS = ["script", "style"].freeze

    FORBIDDEN_CONTEXTS = [:script, :style, :script_attr, :style_attr, :unquoted_attr].freeze

    TAG_OPEN_PATTERN = /<\s*([a-zA-Z][a-zA-Z0-9\-]*)/
    TAG_CLOSE_PATTERN = /<\s*\/\s*([a-zA-Z][a-zA-Z0-9\-]*)/
    ATTR_NAME_PATTERN = /[a-zA-Z_:][a-zA-Z0-9_:.\-]*/

    def initialize
      @state = :text # :text, :tag, or :quoted_attr
      @quote = nil
      @attr_name = nil
      @pending_attr = nil
      @equals_seen = false
      @raw_text_element = nil # "script" or "style" while inside such an element
    end

    # The HTML context of the current parse position.
    def current_context
      case @state
      when :text
        @raw_text_element ? @raw_text_element.to_sym : :text
      when :quoted_attr
        name = @attr_name
        return :script_attr if name && name.start_with?("on")
        return :style_attr if name == "style"

        URL_ATTRIBUTES.include?(name) ? :url : :attr
      else # :tag
        :unquoted_attr
      end
    end

    # Feeds a chunk of static template text to the tracker.
    def feed(text)
      pos = 0
      len = text.length
      while pos < len
        case @state
        when :text
          pos = feed_text(text, pos)
        when :tag
          pos = feed_tag(text, pos)
        else # :quoted_attr
          pos = feed_quoted_attr(text, pos)
        end
      end
    end

    private

    def feed_text(text, pos)
      if text.getbyte(pos) == 60 # '<'
        if (match = TAG_CLOSE_PATTERN.match(text, pos)) && match.begin(0) == pos
          name = match[1].downcase
          @raw_text_element = nil if @raw_text_element == name
          enter_tag
          return match.end(0)
        elsif (match = TAG_OPEN_PATTERN.match(text, pos)) && match.begin(0) == pos
          name = match[1].downcase
          @raw_text_element = name if RAW_TEXT_ELEMENTS.include?(name)
          enter_tag
          return match.end(0)
        elsif text[pos, 4] == "<!--"
          comment_end = text.index("-->", pos + 4)
          return comment_end ? comment_end + 3 : text.length
        end
      end
      pos + 1
    end

    def feed_tag(text, pos)
      byte = text.getbyte(pos)
      case byte
      when 62 # '>'
        @state = :text
        reset_attr
        pos + 1
      when 34, 39 # '"', "'"
        if @equals_seen
          @state = :quoted_attr
          @quote = byte
          @attr_name = @pending_attr
          @equals_seen = false
        end
        pos + 1
      when 61 # '='
        @equals_seen = true
        pos + 1
      else
        if (match = ATTR_NAME_PATTERN.match(text, pos)) && match.begin(0) == pos
          @pending_attr = match[0].downcase
          @equals_seen = false
          match.end(0)
        else
          pos + 1
        end
      end
    end

    def feed_quoted_attr(text, pos)
      if text.getbyte(pos) == @quote
        @state = :tag
        reset_attr
      end
      pos + 1
    end

    def enter_tag
      @state = :tag
      reset_attr
    end

    def reset_attr
      @pending_attr = nil
      @equals_seen = false
      @quote = nil
    end
  end
end
