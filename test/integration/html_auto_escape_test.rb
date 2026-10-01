# frozen_string_literal: true

require 'test_helper'

class HtmlAutoEscapeTest < Minitest::Test
  # A value containing every character the escapers care about.
  EVIL = %(a"b'<c>&d).freeze
  BODY_ESCAPED = "a\"b'&lt;c&gt;&amp;d".freeze
  ATTR_ESCAPED = "a&quot;b&#39;&lt;c&gt;&amp;d".freeze

  def render(source, assigns = {}, options = {})
    template = Liquid::Template.parse(source, autoescape: true,
      environment: options[:environment] || Liquid::Environment.default)
    template.render!(assigns)
  end

  def assert_escape_error(source, assigns = {})
    assert_raises(Liquid::AutoEscapeError) do
      Liquid::Template.parse(source, autoescape: true).render!(assigns)
    end
  end

  # ---- default behaviour is unchanged ------------------------------------

  def test_default_rendering_is_unchanged
    template = Liquid::Template.parse("<p>{{ v }}</p><a title=\"{{ v }}\">{{ v }}</a>")
    assert_equal("<p>#{EVIL}</p><a title=\"#{EVIL}\">#{EVIL}</a>", template.render!('v' => EVIL))
  end

  def test_autoescape_can_be_enabled_at_render_time
    template = Liquid::Template.parse("<p>{{ v }}</p>")
    refute_includes(template.render!('v' => EVIL), '&lt;')
    out = template.render!({ 'v' => EVIL }, autoescape: true)
    assert_includes(out, '&lt;c&gt;')
    refute_includes(out, '<c>')
  end

  # ---- body / attribute / URL contexts -----------------------------------

  def test_body_escapes_markup_but_not_quotes
    assert_equal("<p>#{BODY_ESCAPED}</p>", render("<p>{{ v }}</p>", 'v' => EVIL))
  end

  def test_quoted_attribute_escapes_quotes_and_markup
    assert_equal("<a title=\"#{ATTR_ESCAPED}\">",
      render('<a title="{{ v }}">', 'v' => EVIL))
  end

  def test_single_quoted_attribute_escapes_single_quote
    assert_equal("<a title='#{ATTR_ESCAPED}'>",
      render("<a title='{{ v }}'>", 'v' => EVIL))
  end

  def test_url_attribute_percent_encodes_ampersand
    assert_equal('<a href="/search?q=1%26x=2">',
      render('<a href="{{ u }}">', 'u' => '/search?q=1&x=2'))
  end

  def test_url_attribute_encodes_quote_breaking_characters
    out = render('<a href="{{ u }}">', 'u' => '/x" onmouseover="alert(1)')
    # the quotes inside the value are percent encoded, so no new attribute can start
    assert_equal('<a href="/x%22%20onmouseover=%22alert(1)">', out)
    assert_includes(out, '%22')
  end

  def test_safe_schemes_are_allowed
    {
      'http://x.com/a' => 'http://x.com/a',
      'https://x.com' => 'https://x.com',
      'ftp://x.com' => 'ftp://x.com',
      'mailto:a@b.com' => 'mailto:a@b.com',
      'tel:+123' => 'tel:+123',
      '/path' => '/path',
      '#frag' => '#frag',
      '?q=1' => '?q=1',
      '//x.com/y' => '//x.com/y',
    }.each do |input, expected|
      assert_equal("<a href=\"#{expected}\">", render('<a href="{{ u }}">', 'u' => input))
    end
  end

  def test_dangerous_schemes_are_rejected
    %w[javascript:alert(1) data:text/html,<x> vbscript:msgbox file:///etc/passwd].each do |url|
      assert_raises(Liquid::UnsafeUrlError) { render('<a href="{{ u }}">', 'u' => url) }
    end
  end

  def test_obfuscated_schemes_are_rejected
    assert_raises(Liquid::UnsafeUrlError) { render('<a href="{{ u }}">', 'u' => '  javascript:x') }
    assert_raises(Liquid::UnsafeUrlError) { render('<a href="{{ u }}">', 'u' => "java\tscript:x") }
    assert_raises(Liquid::UnsafeUrlError) { render('<a href="{{ u }}">', 'u' => 'javascript&#58;x') }
    assert_raises(Liquid::UnsafeUrlError) { render('<a href="{{ u }}">', 'u' => 'javascript&#x3A;x') }
  end

  # ---- positions where dynamic content is forbidden ----------------------

  def test_script_interpolation_is_rejected
    err = assert_escape_error("<script>{{ v }}</script>", 'v' => 'x')
    assert_match(/script/, err.message)
  end

  def test_style_interpolation_is_rejected
    assert_escape_error("<style>{{ v }}</style>", 'v' => 'x')
  end

  def test_uppercase_rawtext_is_rejected
    assert_escape_error("<SCRIPT>{{ v }}</SCRIPT>", 'v' => 'x')
  end

  def test_unquoted_attribute_is_rejected
    assert_escape_error("<a href={{ v }}>x</a>", 'v' => 'x')
  end

  def test_comment_interpolation_is_rejected
    assert_escape_error("<!-- {{ v }} -->", 'v' => 'x')
  end

  def test_tag_name_interpolation_is_rejected
    assert_escape_error("<{{ v }}>", 'v' => 'x')
  end

  def test_attribute_name_interpolation_is_rejected
    assert_escape_error("<a {{ v }}>", 'v' => 'x')
  end

  # ---- no double escaping -------------------------------------------------

  def test_escape_filter_is_idempotent_in_body
    assert_equal("<p>#{ATTR_ESCAPED}</p>",
      render("<p>{{ v | escape }}</p>", 'v' => EVIL))
  end

  def test_escape_twice_does_not_double_escape
    out = render("<p>{{ v | escape | escape }}</p>", 'v' => EVIL)
    assert_equal("<p>#{ATTR_ESCAPED}</p>", out)
  end

  def test_escape_once_is_idempotent
    out = render("<p>{{ v | escape | escape_once }}</p>", 'v' => EVIL)
    assert_equal("<p>#{ATTR_ESCAPED}</p>", out)
  end

  # ---- filter chain safety categories ------------------------------------

  def test_case_changing_filter_escapes_original_text
    # upcase runs on the raw value in body context, where a quote is not
    # escaped; the body escaper encodes only markup characters.
    assert_equal('<p>A"B</p>', render('<p>{{ v | upcase }}</p>', 'v' => 'a"b'))
    assert_equal('<p>A&lt;B&gt;</p>', render('<p>{{ v | upcase }}</p>', 'v' => 'a<b>'))
  end

  def test_strip_preserves_category
    assert_equal("<p>#{ATTR_ESCAPED}</p>",
      render("<p>{{ v | escape | strip }}</p>", 'v' => " #{EVIL} "))
  end

  def test_undeclared_known_filter_demotes_trust
    # A registered custom filter that is not declared safe cannot be trusted
    # to preserve escaping, so its output is escaped again at the output.
    mod = Module.new do
      def self.name
        "UndeclaredAutoEscapeTestFilters"
      end

      def identity(input)
        input.to_s
      end
    end
    environment = Liquid::Environment.build do |env|
      env.register_filter(mod)
    end
    template = Liquid::Template.parse("<p>{{ v | escape | identity }}</p>",
      autoescape: true, environment: environment)
    assert_includes(template.render!('v' => EVIL), '&amp;lt;')
  end

  def test_undefined_filter_is_identity_in_lax_mode
    # In lax mode an undefined filter is a no-op, so an already safe value is
    # not double escaped.
    out = render("<p>{{ v | escape | does_not_exist }}</p>", 'v' => '<a>')
    assert_equal('<p>&lt;a&gt;</p>', out)
  end

  def test_append_with_untrusted_fragment_demotes_whole_value
    # An escaped first operand joined to an untrusted fragment cannot be
    # trusted as a whole: the result is escaped again at the output position.
    out = render("<p>{{ a | escape | append: b }}</p>", 'a' => '<a>', 'b' => '<b>')
    assert_includes(out, '&amp;lt;a&amp;gt;')
    assert_includes(out, '&lt;b&gt;')
  end

  def test_url_encode_is_safe_in_url_context
    assert_equal('<a href="a%22b%27%3Cc%3E%26d">',
      render('<a href="{{ v | url_encode }}">', 'v' => EVIL))
  end

  def test_newline_to_br_emits_safe_markup
    assert_equal("<p>a<br />\nb</p>", render("<p>{{ v | newline_to_br }}</p>", 'v' => "a\nb"))
  end

  # ---- capture ------------------------------------------------------------

  def test_capture_in_body_produces_html_safe_fragment
    src = '{% capture c %}<b>{{ v }}</b>{% endcapture %}<div>{{ c }}</div>'
    assert_equal("<div><b>#{BODY_ESCAPED}</b></div>", render(src, 'v' => EVIL))
  end

  def test_capture_inside_attribute_is_attribute_safe_when_used_in_attribute
    src = '<a title="{% capture c %}{{ v }}{% endcapture %}">[{{ c }}]</a>'
    out = render(src, 'v' => EVIL)
    assert_includes(out, "<a title=\"\">[#{ATTR_ESCAPED}]</a>")
  end

  def test_capture_inside_url_is_url_safe
    # A capture positioned inside a URL attribute produces a url-safe
    # fragment; it is emitted verbatim when later used in a URL attribute.
    src = '<a href="{% capture u %}/s?q={{ q }}{% endcapture %}"></a><a href="{{ u }}">x</a>'
    assert_equal('<a href=""></a><a href="/s?q=a%26b">x</a>', render(src, 'q' => 'a&b'))
  end

  def test_capture_inside_url_attribute_body_is_also_url_safe
    src = '<a href="{% capture u %}/s?q={{ q }}{% endcapture %}">{{ u }}</a>'
    assert_equal('<a href="">/s?q=a%26b</a>', render(src, 'q' => 'a&b'))
  end

  def test_capture_does_not_advance_parent_stream
    src = '<a title="{% capture c %}x{% endcapture %}">y</a>'
    assert_equal('<a title="">y</a>', render(src))
  end

  # ---- render / include partials -----------------------------------------

  def build_environment(partials)
    file_system = Object.new
    file_system.define_singleton_method(:read_template_file) do |name|
      partials.fetch(name)
    end
    Liquid::Environment.build(file_system: file_system) {}
  end

  def test_render_partial_inherits_body_context
    env = build_environment('snip' => '<b>{{ v }}</b>')
    assert_equal("<b>#{BODY_ESCAPED}</b>",
      render("{% render 'snip' with val as v %}", { 'val' => EVIL }, { environment: env }))
  end

  def test_render_partial_inherits_attribute_context
    env = build_environment('snip' => '{{ v }}')
    out = render('<a title="{% render \'snip\' with val as v %}">x</a>',
      { 'val' => EVIL }, { environment: env })
    assert_equal("<a title=\"#{ATTR_ESCAPED}\">x</a>", out)
  end

  def test_render_partial_inherits_url_context
    env = build_environment('snip' => '{{ u }}')
    assert_equal('<a href="/p%26q">x</a>',
      render('<a href="{% render \'snip\' with val as u %}">x</a>',
        { 'val' => '/p&q' }, { environment: env }))
    assert_raises(Liquid::UnsafeUrlError) do
      render('<a href="{% render \'snip\' with val as u %}">x</a>',
        { 'val' => 'javascript:x' }, { environment: env })
    end
  end

  def test_stream_continues_after_partial
    env = build_environment('snip' => '<b>{{ v }}</b>')
    out = render('<p>{% render \'snip\' with val as v %}</p><a title="{{ v }}">',
      { 'v' => EVIL, 'val' => EVIL }, { environment: env })
    assert_includes(out, '<p><b>')
    assert_includes(out, "<a title=\"#{ATTR_ESCAPED}\">")
  end

  # ---- control flow -------------------------------------------------------

  def test_for_loop_keeps_context
    # body context escapes markup; a bare quote is harmless in body text
    assert_equal('<li>&lt;a&gt;</li><li>b"</li>',
      render('{% for i in items %}<li>{{ i }}</li>{% endfor %}', 'items' => ['<a>', 'b"']))
  end

  def test_untaken_branch_does_not_corrupt_context
    out = render('{% if false %}<x{% endif %}<a href="{{ u }}">', 'u' => '/x')
    assert_equal('<a href="/x">', out)
  end

  def test_echo_tag_uses_context
    assert_equal("<a title=\"#{ATTR_ESCAPED}\">",
      render('<a title="{% echo v %}">', 'v' => EVIL))
  end

  def test_arrays_are_element_wise_escaped_in_attributes
    assert_equal('<a title="&lt;a&gt;b&quot;"></a>',
      render('<a title="{{ arr }}"></a>', 'arr' => ['<a>', 'b"']))
  end

  def test_arrays_are_element_wise_escaped_in_body
    assert_equal('<p>&lt;a&gt;b"</p>',
      render('<p>{{ arr }}</p>', 'arr' => ['<a>', 'b"']))
  end

  def test_numbers_and_booleans_render_normally
    assert_equal('<p>42true</p>', render('<p>{{ n }}{{ b }}</p>', 'n' => 42, 'b' => true))
  end

  def test_raw_tag_is_static_text
    assert_equal('{{ v }}', render('{% raw %}{{ v }}{% endraw %}', 'v' => EVIL))
  end

  # ---- ruby SafeString semantics -----------------------------------------

  def test_safe_string_concatenation_with_untrusted_is_demoted
    safe = Liquid::SafeString.new('&lt;a&gt;', :html)
    result = safe + '<b>'
    refute_kind_of(Liquid::SafeString, result)
    assert_equal('&lt;a&gt;<b>', result)
  end

  def test_safe_string_concatenation_with_same_category_is_trusted
    a = Liquid::SafeString.new('a', :html)
    b = Liquid::SafeString.new('b', :html)
    result = a + b
    assert_kind_of(Liquid::SafeString, result)
    assert_equal(:html, result.safe_category)
  end

  def test_safe_string_cross_category_concatenation_is_demoted
    a = Liquid::SafeString.new('a', :html)
    b = Liquid::SafeString.new('b', :url)
    refute_kind_of(Liquid::SafeString, a + b)
  end

  def test_safe_string_safe_for
    html = Liquid::SafeString.new('x', :html)
    attribute = Liquid::SafeString.new('x', :attribute)
    url = Liquid::SafeString.new('x', :url)
    assert(url.safe_for?(:url) && url.safe_for?(:attribute) && url.safe_for?(:html))
    assert(attribute.safe_for?(:attribute) && attribute.safe_for?(:html))
    refute(attribute.safe_for?(:url))
    assert(html.safe_for?(:html))
    refute(html.safe_for?(:attribute))
  end
end
