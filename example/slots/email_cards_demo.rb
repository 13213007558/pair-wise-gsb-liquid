# frozen_string_literal: true

# Demonstration of named content slots on the `render` tag.
#
# Run with: ruby example/slots/email_cards_demo.rb
$LOAD_PATH.unshift(File.expand_path('../../lib', __dir__))
require 'liquid'

partials = {
  # The card renders a NESTED snippet for its heading, then marks an `actions`
  # slot where the caller injects its operation area. A slot's own body is the
  # default content used when the caller supplies nothing.
  'email_card' => <<~LIQUID,
    ┌─ email card ───────────────
    │ {% render 'email_card_heading', title: card.title %}
    │ actions → {% slot actions %}default action{% endslot %}
    └────────────────────────────
  LIQUID

  # The nested snippet also declares a slot, but the caller's slot is scoped
  # to the outer render only, so the nested snippet always renders its own
  # default content.
  'email_card_heading' => '✉ {{ title }} ({% slot eyebrow %}weekly{% endslot %})',
}

file_system = Class.new do
  def initialize(partials)
    @partials = partials
  end

  def read_template_file(name)
    @partials.fetch(name)
  end
end.new(partials)

environment = Liquid::Environment.build(file_system: file_system)

# Two cards with the SAME title; `render ... for` binds a different card on
# every iteration, so each card renders its own independently-bound action.
template = Liquid::Template.parse(<<~LIQUID, environment: environment)
  {% render 'email_card' for emails as card %}
    {% slot actions %}[{{ card.action }} → {{ card.target }}]{% endslot %}
  {% endrender %}
LIQUID

emails = [
  { 'title' => 'Your weekly digest', 'action' => 'Read online', 'target' => '/inbox' },
  { 'title' => 'Your weekly digest', 'action' => 'Unsubscribe', 'target' => '/settings' },
]

puts template.render!('emails' => emails)

puts
puts 'Without a supplied slot, the snippet falls back to its default content:'
puts Liquid::Template.parse(
  "{% render 'email_card' with card as card %}",
  environment: environment,
).render!('card' => { 'title' => 'Your weekly digest' })
