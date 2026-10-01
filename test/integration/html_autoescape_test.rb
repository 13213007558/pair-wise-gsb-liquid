# frozen_string_literal: true

require 'test_helper'

class HtmlAutoescapeTest < Minitest::Test
  include Liquid

  # A value containing both quotes and angle brackets, used across contexts.
  PAYLOAD = %q{"><img src=x onerror=alert(1)>}
  ESCAPED_PAYLOAD = "&quot;&gt;&lt;img src=x onerror=alert(1)&gt;"

  def autoescape_environment(partials: {})
    Liquid::Environment.build(
      file_system: StubFileSystem.new(partials),
      html_autoescape: true,
    )
  end

  def render_autoescape(template, assigns = {}, partials: {}, environment: nil)
    environment ||= autoescape_environment(partials: partials)
    file_system = environment.file_system
    registers = Liquid::Registers.new(file_system: file_system, template_factory: Liquid::TemplateFactory.new)
    context = Liquid::Context.build(
      static_environments: assigns,
      registers: registers,
      environment: environment,
    )
    Liquid::Template.parse(template, environment: environment).render(context)
  end

  def assert_rejected_at_parse(template, message_fragment, environment: nil)
    environment ||= autoescape_environment
    exception = assert_raises(Liquid::SyntaxError) do
      Liquid::Template.parse(template, environment: environment)
    end
    assert_match(message_fragment, exception.message)
  end

  def test_default_rendering_is_unchanged_without_autoescape
    assert_template_result("<p>#{PAYLOAD}</p>", "<p>{{ x }}</p>", { "x" => PAYLOAD })
  end

  def test_text_context_is_escaped
    assert_equal(
      "<p>#{ESCAPED_PAYLOAD}</p>",
      render_autoescape("<p>{{ x }}</p>", { "x" => PAYLOAD }),
    )
  end

  def test_double_quoted_attribute_context_is_escaped
    assert_equal(
      %(<div title="#{ESCAPED_PAYLOAD}">),
      render_autoescape('<div title="{{ x }}">', { "x" => PAYLOAD }),
    )
  end

  def test_single_quoted_attribute_context_is_escaped
    assert_equal(
      %(<div title='#{ESCAPED_PAYLOAD}'>),
      render_autoescape("<div title='{{ x }}'>", { "x" => PAYLOAD }),
    )
  end

  def test_same_value_in_several_positions
    template = <<~LIQUID
      <p>{{ x }}</p>
      <div title="{{ x }}"></div>
      <a href="{{ u }}">link</a>
    LIQUID
    expected = <<~HTML
      <p>#{ESCAPED_PAYLOAD}</p>
      <div title="#{ESCAPED_PAYLOAD}"></div>
      <a href="https://example.com/?a=1&amp;b=2">link</a>
    HTML
    assert_equal(
      expected,
      render_autoescape(template, { "x" => PAYLOAD, "u" => "https://example.com/?a=1&b=2" }),
    )
  end

  def test_url_attribute_allows_safe_schemes_and_relative_urls
    environment = autoescape_environment
    [
      "https://example.com/?a=1&b=2",
      "http://example.com",
      "mailto:user@example.com",
      "tel:+1234567890",
      "/relative/path?x=1&y=2",
      "relative",
      "#fragment",
      "//example.com/protocol-relative",
    ].each do |url|
      template = Liquid::Template.parse('<a href="{{ u }}">x</a>', environment: environment)
      output = template.render("u" => url)
      assert_equal(%(<a href="#{url.gsub("&", "&amp;")}">x</a>), output, "expected #{url.inspect} to be allowed")
    end
  end

  def test_url_attribute_rejects_dangerous_schemes
    environment = autoescape_environment
    [
      "javascript:alert(1)",
      "JaVaScRiPt:alert(1)",
      "java\tscript:alert(1)",
      "data:text/html;base64,PHNjcmlwdD4=",
      "vbscript:msgbox(1)",
    ].each do |url|
      template = Liquid::Template.parse('<a href="{{ u }}">x</a>', environment: environment)
      error = assert_raises(Liquid::UnsafeUrlError) do
        template.render!("u" => url)
      end
      assert_match("unsafe URL scheme", error.message)
    end
  end

  def test_script_element_is_rejected
    assert_rejected_at_parse("<script>{{ x }}</script>", "<script> element")
  end

  def test_style_element_is_rejected
    assert_rejected_at_parse("<style>{{ x }}</style>", "<style> element")
  end

  def test_unquoted_attribute_is_rejected
    assert_rejected_at_parse("<div class={{ x }}>", "unquoted attribute")
  end

  def test_bare_interpolation_inside_tag_is_rejected
    assert_rejected_at_parse("<div {{ x }}>", "unquoted attribute")
  end

  def test_event_handler_attribute_is_rejected
    assert_rejected_at_parse('<div onclick="{{ x }}">', "event handler attribute")
  end

  def test_style_attribute_is_rejected
    assert_rejected_at_parse('<div style="{{ x }}">', "style attribute")
  end

  def test_echo_tag_is_escaped_and_rejected_in_script
    assert_equal(
      "<p>#{ESCAPED_PAYLOAD}</p>",
      render_autoescape("<p>{% echo x %}</p>", { "x" => PAYLOAD }),
    )
    assert_rejected_at_parse("<script>{% echo x %}</script>", "<script> element")
  end

  def test_escape_filter_output_is_not_double_escaped
    assert_equal(
      ESCAPED_PAYLOAD,
      render_autoescape("{{ x | escape }}", { "x" => PAYLOAD }),
    )
    assert_equal(
      ESCAPED_PAYLOAD,
      render_autoescape("{{ x | escape | escape }}", { "x" => PAYLOAD }),
    )
  end

  def test_escape_once_output_is_not_double_escaped
    assert_equal(
      "&lt;strong&gt;Hulk&lt;/strong&gt;",
      render_autoescape("{{ x | escape_once }}", { "x" => "&lt;strong&gt;Hulk</strong>" }),
    )
  end

  def test_capture_output_is_not_double_escaped
    assert_equal(
      "<p>#{ESCAPED_PAYLOAD}</p>",
      render_autoescape("{% capture c %}<p>{{ x }}</p>{% endcapture %}{{ c }}", { "x" => PAYLOAD }),
    )
  end

  def test_capture_output_is_marked_safe_only_when_autoescape_enabled
    # Default mode: capture keeps returning a plain String
    template = Liquid::Template.parse("{% capture c %}x{% endcapture %}{{ c }}", error_mode: :strict)
    assert_equal("x", template.render)
  end

  def test_plain_string_concatenation_does_not_inherit_trust
    # Appending to an escaped fragment yields a plain, untrusted string which
    # is escaped as a whole on output: the previously escaped entities are
    # escaped again rather than the safe fragment lending trust to the whole.
    escaped_twice = ESCAPED_PAYLOAD.gsub("&", "&amp;")
    assert_equal(
      "<p>#{escaped_twice}&lt;b&gt;</p>",
      render_autoescape("<p>{{ x | escape | append: suffix }}</p>", { "x" => PAYLOAD, "suffix" => "<b>" }),
    )
  end

  def test_assign_preserves_safety_of_captured_content
    assert_equal(
      "<p>#{ESCAPED_PAYLOAD}</p>",
      render_autoescape("{% capture c %}<p>{{ x }}</p>{% endcapture %}{% assign d = c %}{{ d }}", { "x" => PAYLOAD }),
    )
  end

  def test_render_tag_escapes_passed_variables_in_partial_context
    assert_equal(
      "<b>#{ESCAPED_PAYLOAD}</b>",
      render_autoescape('{% render "snippet", t: x %}', { "x" => PAYLOAD }, partials: { "snippet" => "<b>{{ t }}</b>" }),
    )
  end

  def test_render_tag_does_not_double_escape_captured_content
    assert_equal(
      "<b><p>#{ESCAPED_PAYLOAD}</p></b>",
      render_autoescape(
        '{% capture c %}<p>{{ x }}</p>{% endcapture %}{% render "snippet", t: c %}',
        { "x" => PAYLOAD },
        partials: { "snippet" => "<b>{{ t }}</b>" },
      ),
    )
  end

  def test_render_tag_partial_rejects_forbidden_context
    environment = autoescape_environment(partials: { "snippet" => "<script>{{ t }}</script>" })
    file_system = environment.file_system
    registers = Liquid::Registers.new(file_system: file_system, template_factory: Liquid::TemplateFactory.new)
    context = Liquid::Context.build(static_environments: { "x" => "1" }, registers: registers, environment: environment)
    template = Liquid::Template.parse('{% render "snippet", t: x %}', environment: environment)
    error = assert_raises(Liquid::SyntaxError) { template.render!(context) }
    assert_match("<script> element", error.message)
  end

  def test_url_encode_is_trusted_in_url_attribute
    assert_equal(
      '<a href="/search?q=a+b%26c">x</a>',
      render_autoescape('<a href="/search?q={{ q | url_encode }}">x</a>', { "q" => "a b&c" }),
    )
  end

  def test_html_safe_value_is_not_trusted_in_url_attribute
    environment = autoescape_environment
    template = Liquid::Template.parse('<a href="{{ u }}">x</a>', environment: environment)
    error = assert_raises(Liquid::UnsafeUrlError) do
      template.render!("u" => Liquid::SafeString.new("javascript:alert(1)", :html))
    end
    assert_match("unsafe URL scheme", error.message)
  end

  def test_url_safe_value_is_trusted_everywhere
    environment = autoescape_environment
    safe_url = Liquid::SafeString.new("https://example.com/?a=1&amp;b=2", :url)
    assert_equal(
      "<p>https://example.com/?a=1&amp;b=2</p>",
      Liquid::Template.parse("<p>{{ u }}</p>", environment: environment).render("u" => safe_url),
    )
    assert_equal(
      '<a href="https://example.com/?a=1&amp;b=2">x</a>',
      Liquid::Template.parse('<a href="{{ u }}">x</a>', environment: environment).render("u" => safe_url),
    )
  end

  def test_html_autoescape_can_be_enabled_per_template_via_parse_options
    template = Liquid::Template.parse("{{ x }}", html_autoescape: true)
    assert_equal(ESCAPED_PAYLOAD, template.render("x" => PAYLOAD))
  end

  def test_numbers_and_nil_render_normally
    assert_equal("<p>5</p>", render_autoescape("<p>{{ x }}</p>", { "x" => 5 }))
    assert_equal("<p></p>", render_autoescape("<p>{{ x }}</p>", { "x" => nil }))
  end

  def test_safe_string_concatenation_returns_plain_string
    combined = Liquid::SafeString.new("<b>safe</b>", :html) + "<i>x</i>"
    assert_instance_of(String, combined)
    refute_instance_of(Liquid::SafeString, combined)
  end
end
