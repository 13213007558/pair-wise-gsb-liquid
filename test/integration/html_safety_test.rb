# frozen_string_literal: true

require 'test_helper'

class HtmlSafetyTest < Minitest::Test
  include Liquid

  def render_html(source, assigns = nil, partials: nil, **assign_kwargs)
    assigns = (assigns || {}).merge(assign_kwargs.transform_keys(&:to_s))
    environment = Liquid::Environment.build(file_system: StubFileSystem.new(partials || {}))
    template = Liquid::Template.parse(source, html_safe: true, environment: environment)
    template.render!(assigns)
  end

  def test_plain_text_rendering_remains_unchanged
    template = Liquid::Template.parse("{{ value }}")
    assert_equal('<b onclick="x">', template.render!('value' => '<b onclick="x">'))
  end

  def test_escapes_body_text
    assert_equal(
      '<p>&lt;b&gt;&amp;&#39;&quot;</p>',
      render_html('<p>{{ value }}</p>', 'value' => %q(<b>&'")),
    )
  end

  def test_escapes_quoted_attributes
    assert_equal(
      %q(<a title="&quot;&#39;&lt;&gt;&amp;" href="/x">x</a>),
      render_html(
        %q(<a title="{{ value }}" href="/x">x</a>),
        'value' => %q("'<>&),
      ),
    )
  end

  def test_does_not_double_escape_values_passed_through_escape
    assert_equal(
      '<p>&lt;b&gt;</p>',
      render_html('<p>{{ value | escape }}</p>', 'value' => '<b>'),
    )
  end

  def test_renders_safe_relative_url_values
    assert_equal(
      '<a href="/search?q=a%20b&amp;c">x</a>',
      render_html('<a href="{{ value }}">x</a>', 'value' => '/search?q=a b&c'),
    )
  end

  def test_neutralizes_dangerous_url_schemes
    assert_equal(
      '<a href="javascript%3Aalert%281%29">x</a>',
      render_html('<a href="{{ value }}">x</a>', 'value' => 'javascript:alert(1)'),
    )
  end

  def test_rejects_static_dangerous_url_schemes
    assert_raises(HtmlSafetyError) do
      render_html('<a href="javascript:alert(1)">x</a>')
    end
  end

  def test_rejects_dangerous_url_schemes_started_before_interpolation
    assert_raises(HtmlSafetyError) do
      render_html('<a href="javascript:{{ value }}">x</a>', 'value' => 'alert(1)')
    end
  end

  def test_rejects_dangerous_url_schemes_hidden_by_entities
    assert_raises(HtmlSafetyError) do
      render_html('<a href="java&#115;cript:{{ value }}">x</a>', 'value' => 'alert(1)')
    end
  end

  def test_neutralizes_dangerous_srcset_urls
    output = render_html('<img srcset="{{ value }}">', 'value' => '/safe.jpg 1x, javascript:alert(1) 2x')
    refute_includes(output, 'javascript:')
  end

  def test_rejects_event_handler_interpolation
    assert_raises(HtmlSafetyError) do
      render_html('<button onclick="{{ value }}">x</button>', 'value' => 'alert(1)')
    end
  end

  def test_rejects_style_attribute_interpolation
    assert_raises(HtmlSafetyError) do
      render_html('<span style="color:{{ value }}">x</span>', 'value' => 'red')
    end
  end

  def test_rejects_script_and_style_content_interpolation
    assert_raises(HtmlSafetyError) do
      render_html('<script>{{ value }}</script>', 'value' => '1')
    end

    assert_raises(HtmlSafetyError) do
      render_html('<style>{{ value }}</style>', 'value' => '1')
    end
  end

  def test_rejects_tag_name_and_attribute_name_interpolation
    assert_raises(HtmlSafetyError) do
      render_html('<{{ tag }}>x</{{ tag }}>', 'tag' => 'script')
    end

    assert_raises(HtmlSafetyError) do
      render_html('<div {{ name }}="x">x</div>', 'name' => 'onclick')
    end
  end

  def test_rejects_unquoted_attributes
    assert_raises(HtmlSafetyError) do
      render_html('<a title={{ value }}>x</a>', 'value' => 'x')
    end
  end

  def test_conditional_branches_share_and_restore_text_context
    source = '<a title="{% if true %}{{ value }}{% endif %}">x</a>'
    assert_equal('<a title="a&quot;b">x</a>', render_html(source, 'value' => 'a"b'))

    source = '{% if false %}{% else %}<p>{{ value }}</p>{% endif %}'
    assert_equal('<p>&lt;b&gt;</p>', render_html(source, 'value' => '<b>'))
  end

  def test_conditional_branches_do_not_leak_attribute_state
    source = '{% if false %}<a title="x{% endif %}{{ value }}'
    assert_equal('&lt;b&gt;', render_html(source, 'value' => '<b>'))
  end

  def test_captured_fragments_can_be_reused_in_text_context
    source = '{% capture fragment %}<b>{{ value }}</b>{% endcapture %}<div>{{ fragment }}</div>'
    assert_equal('<div><b>&lt;b&gt;</b></div>', render_html(source, 'value' => '<b>'))
  end

  def test_captured_fragments_cannot_be_reused_in_attributes
    source = '{% capture fragment %}<b>x</b>{% endcapture %}<a title="{{ fragment }}">x</a>'
    assert_raises(HtmlSafetyError) do
      render_html(source)
    end
  end

  def test_capture_rejects_fragment_left_inside_an_attribute
    source = '{% capture fragment %}<a title="x{% endcapture %}{{ fragment }}'
    assert_raises(HtmlSafetyError) do
      render_html(source)
    end
  end

  def test_render_partials_share_the_surrounding_tag_context
    source = '<a {% render "snippet", value: danger %}>x</a>'
    partials = { 'snippet' => 'title="{{ value }}"' }
    assert_equal(
      '<a title="a&quot;&lt;&gt;">x</a>',
      render_html(source, 'danger' => 'a"<>', partials: partials),
    )
  end

  def test_render_partials_continue_the_surrounding_body_context
    source = '{% render "snippet" %}<span>{{ value }}</span>'
    partials = { 'snippet' => '<b>safe</b>' }
    assert_equal(
      '<b>safe</b><span>&lt;b&gt;</span>',
      render_html(source, 'value' => '<b>', partials: partials),
    )
  end

  def test_render_partials_neutralize_dangerous_shared_url_context
    source = '<a href="{% render "snippet", value: danger %}">x</a>'
    partials = { 'snippet' => '{{ value }}' }
    assert_equal(
      '<a href="javascript%3Aalert%281%29">x</a>',
      render_html(source, 'danger' => 'javascript:alert(1)', partials: partials),
    )
  end

  def test_render_partials_can_close_a_started_tag
    source = '<b>{% render "snippet", value: danger %}'
    partials = { 'snippet' => '{{ value }}</b>' }
    assert_equal(
      '<b>&lt;script&gt;alert(1)&lt;/script&gt;</b>',
      render_html(source, 'danger' => '<script>alert(1)</script>', partials: partials),
    )
  end

  def test_html_safe_mode_can_be_enabled_per_render
    template = Liquid::Template.parse('<p>{{ value }}</p>')
    assert_equal('<p>&lt;b&gt;</p>', template.render!({ 'value' => '<b>' }, html_safe: true))
    assert_equal('<p><b></p>', template.render!('value' => '<b>'))
  end
end
