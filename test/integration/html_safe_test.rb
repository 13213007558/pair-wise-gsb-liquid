# frozen_string_literal: true

require 'test_helper'

class HTMLSafeTest < Minitest::Test
  def render_html(template, assigns = {}, partials = nil, safe = true)
    file_system = StubFileSystem.new(partials || {})
    environment = Liquid::Environment.build(file_system: file_system)
    template = Liquid::Template.parse(template, environment: environment, html_safe: safe)
    template.render!(assigns)
  end

  def test_text_context_escapes_html
    assert_equal('&lt;b&gt;&amp;&lt;/b&gt;', render_html('{{ x }}', 'x' => '<b>&</b>'))
  end

  def test_text_context_escapes_entities
    assert_equal('&amp;amp; &amp;quot;', render_html('{{ x }}', 'x' => '&amp; &quot;'))
  end

  def test_double_quoted_attribute_escapes_quotes_and_markup
    assert_equal(
      %(<div title="a&quot;b&lt;c&gt;&amp;&#39;">),
      render_html(%(<div title="{{ x }}">), 'x' => %(a"b<c>&')),
    )
  end

  def test_single_quoted_attribute_escapes_quotes
    assert_equal(
      %(<div title='a&#39;b&quot;'>),
      render_html(%(<div title='{{ x }}'>), 'x' => %(a'b")),
    )
  end

  def test_unquoted_attribute_escapes_whitespace_and_separators
    assert_equal(
      %(<div title=a&#32;b&#96;c&#61;d&gt;>),
      render_html(%(<div title={{ x }}>), 'x' => "a b`c=d>"),
    )
  end

  def test_attribute_context_crossing_tag_boundary
    template = '{% if c %}<div title="{% endif %}{{ x }}{% if c %}">{% endif %}'
    assert_equal(
      %(<div title="a&quot;b">),
      render_html(template, 'c' => true, 'x' => 'a"b'),
    )
    # with the condition false the interpolation lands in text content
    assert_equal('a"b', render_html(template, 'c' => false, 'x' => 'a"b'))
  end

  def test_url_attribute_allows_safe_schemes
    assert_equal(
      %(<a href="https://example.com/?a=1&amp;b=2">x</a>),
      render_html(%(<a href="{{ u }}">x</a>), 'u' => 'https://example.com/?a=1&b=2'),
    )
    assert_equal(%(<a href="/relative/path">), render_html(%(<a href="{{ u }}">), 'u' => '/relative/path'))
    assert_equal(%(<a href="#fragment">), render_html(%(<a href="{{ u }}">), 'u' => '#fragment'))
    assert_equal(%(<a href="mailto:a@b.com">), render_html(%(<a href="{{ u }}">), 'u' => 'mailto:a@b.com'))
  end

  def test_url_attribute_rejects_dangerous_schemes
    [
      'javascript:alert(1)',
      'JaVaScRiPt:alert(1)',
      "java\tscript:alert(1)",
      '  javascript:alert(1)',
      'vbscript:msgbox(1)',
      'data:text/html,<script>alert(1)</script>',
    ].each do |url|
      error = assert_raises(Liquid::HTMLSafeError) do
        render_html(%(<a href="{{ u }}">), 'u' => url)
      end
      assert_match(/unsafe URL scheme/, error.message)
    end
  end

  def test_url_scheme_split_across_literal_and_interpolation
    error = assert_raises(Liquid::HTMLSafeError) do
      render_html(%(<a href="java{{ u }}">), 'u' => 'script:alert(1)')
    end
    assert_match(/unsafe URL scheme/, error.message)
  end

  def test_url_scheme_determined_by_literal_prefix_is_not_rechecked
    assert_equal(
      %(<a href="https://example.com/">),
      render_html(%(<a href="https://{{ u }}/">), 'u' => 'example.com'),
    )
  end

  def test_url_check_applies_to_all_url_attributes
    %w[src action formaction poster].each do |attribute|
      assert_raises(Liquid::HTMLSafeError) do
        render_html(%(<div #{attribute}="{{ u }}">), 'u' => 'javascript:alert(1)')
      end
    end
  end

  def test_event_handler_attributes_are_rejected_at_parse_time
    ['onclick', 'onmouseover', 'ONCLICK'].each do |attribute|
      error = assert_raises(Liquid::HTMLSafeError) do
        render_html(%(<div #{attribute}="{{ x }}">), 'x' => 'alert(1)')
      end
      assert_match(/event handler/, error.message)
    end
  end

  def test_script_content_is_rejected_at_parse_time
    error = assert_raises(Liquid::HTMLSafeError) do
      render_html('<script>{{ x }}</script>', 'x' => 'alert(1)')
    end
    assert_match(/script/, error.message)
  end

  def test_style_content_is_rejected_at_parse_time
    assert_raises(Liquid::HTMLSafeError) do
      render_html('<style>{{ x }}</style>', 'x' => 'body{}')
    end
  end

  def test_script_content_opened_by_condition_is_rejected_at_render_time
    template = '{% if c %}<script>{% endif %}{{ x }}'
    assert_raises(Liquid::HTMLSafeError) do
      render_html(template, 'c' => true, 'x' => 'alert(1)')
    end
    # not taken: the interpolation is plain text
    assert_equal('alert(1)', render_html(template, 'c' => false, 'x' => 'alert(1)'))
  end

  def test_comment_content_is_rejected
    assert_raises(Liquid::HTMLSafeError) do
      render_html('<!-- {{ x }} -->', 'x' => 'x')
    end
  end

  def test_interpolation_between_attributes_is_rejected
    error = assert_raises(Liquid::HTMLSafeError) do
      render_html('<div {{ x }}>', 'x' => 'class="y"')
    end
    assert_match(/inside a tag/, error.message)
  end

  def test_capture_produces_safe_html_for_text_context
    assert_equal(
      '<b>&lt;i&gt;</b>',
      render_html('{% capture c %}<b>{{ x }}</b>{% endcapture %}{{ c }}', 'x' => '<i>'),
    )
  end

  def test_capture_is_escaped_again_inside_attribute
    template = '{% capture c %}a"b{% endcapture %}<div title="{{ c }}">'
    assert_equal(%(<div title="a&quot;b">), render_html(template))
  end

  def test_capture_does_not_disturb_surrounding_context
    template = '<div title="{% capture c %}x{% endcapture %}safe">{{ y }}</div>'
    assert_equal(
      %(<div title="safe">&lt;b&gt;</div>),
      render_html(template, 'y' => '<b>'),
    )
  end

  def test_render_partial_in_text_context
    partials = { 'frag' => '<span>{{ y }}</span>' }
    assert_equal(
      '<div><span>&lt;i&gt;</span></div>',
      render_html("<div>{% render 'frag', y: y %}</div>", { 'y' => '<i>' }, partials),
    )
  end

  def test_render_partial_inside_attribute
    partials = { 'val' => '{{ x }}' }
    assert_equal(
      %(<div title="a&quot;b">),
      render_html(%(<div title="{% render 'val', x: x %}">), { 'x' => 'a"b' }, partials),
    )
  end

  def test_tag_opened_in_template_closed_in_partial
    partials = { 'attrs' => 'class="{{ c }}"' }
    assert_equal(
      %(<div class="x&quot; onmouseover=&quot;alert(1)">),
      render_html(%(<div {% render 'attrs', c: c %}>), { 'c' => 'x" onmouseover="alert(1)' }, partials),
    )
  end

  def test_dangerous_interpolation_inside_partial_is_rejected_at_render_time
    partials = { 's' => '<script>{{ x }}</script>' }
    assert_raises(Liquid::HTMLSafeError) do
      render_html("{% render 's', x: x %}", { 'x' => 'alert(1)' }, partials)
    end
  end

  def test_dangerous_url_inside_partial_is_rejected_at_render_time
    partials = { 'link' => '{{ u }}' }
    assert_raises(Liquid::HTMLSafeError) do
      render_html(%(<a href="{% render 'link', u: u %}">), { 'u' => 'javascript:alert(1)' }, partials)
    end
  end

  def test_echo_tag_is_escaped
    assert_equal('&lt;b&gt;', render_html('{% echo x %}', 'x' => '<b>'))
  end

  def test_echo_inside_liquid_tag_is_escaped
    assert_equal('&lt;b&gt;', render_html("{% liquid\n  echo x\n%}", 'x' => '<b>'))
  end

  def test_cycle_values_are_escaped
    assert_equal('&lt;i&gt;', render_html("{% cycle x, 'b' %}", 'x' => '<i>'))
  end

  def test_array_values_are_escaped_element_wise
    assert_equal('&lt;a&gt;&lt;b&gt;', render_html('{{ x }}', 'x' => ['<a>', '<b>']))
  end

  def test_nil_renders_nothing
    assert_equal('', render_html('{{ x }}', 'x' => nil))
  end

  def test_html_safe_error_is_not_swallowed_in_lax_mode
    # a runtime rejection must raise even when errors are rendered as text
    template = Liquid::Template.parse('{% if c %}<script>{% endif %}{{ x }}', html_safe: true)
    assert_raises(Liquid::HTMLSafeError) do
      template.render('c' => true, 'x' => 'alert(1)')
    end
  end

  def test_plain_text_rendering_is_unchanged_without_opt_in
    assert_equal(%(<div title="a"b">), render_html(%(<div title="{{ x }}">), { 'x' => 'a"b' }, nil, false))
    assert_equal('<b>&</b>', render_html('{{ x }}', { 'x' => '<b>&</b>' }, nil, false))
    assert_equal(
      %(<a href="javascript:alert(1)">),
      render_html(%(<a href="{{ u }}">), { 'u' => 'javascript:alert(1)' }, nil, false),
    )
  end

  def test_environment_level_opt_in
    environment = Liquid::Environment.build { |env| env.html_safe = true }
    template = Liquid::Template.parse('{{ x }}', environment: environment)
    assert_equal('&lt;b&gt;', template.render!('x' => '<b>'))
  end

  def test_template_option_overrides_environment
    environment = Liquid::Environment.build { |env| env.html_safe = true }
    template = Liquid::Template.parse('{{ x }}', environment: environment, html_safe: false)
    assert_equal('<b>', template.render!('x' => '<b>'))
  end

  def test_filters_compose_with_escaping
    assert_equal('&lt;B&gt;', render_html('{{ x | upcase }}', 'x' => '<b>'))
  end

  def test_raw_content_is_tracked
    error = assert_raises(Liquid::HTMLSafeError) do
      render_html('{% raw %}<script>{% endraw %}{{ x }}', 'x' => 'alert(1)')
    end
    assert_match(/script/, error.message)
  end
end
