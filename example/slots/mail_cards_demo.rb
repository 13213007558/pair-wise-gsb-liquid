# frozen_string_literal: true

# Demonstration of named content slots for the render tag.
#
# Run with:
#   ruby example/slots/mail_cards_demo.rb
#
# Two email cards are rendered from one snippet, inside a `render ... for`
# loop. Both cards share the same title, while the caller gives each card a
# different action area through a named slot. The snippets are nested: the
# outer `mail_list` snippet renders the inner `mail_card` snippet once per
# message and transparently forwards the caller supplied `actions` slot.

$LOAD_PATH.unshift(File.expand_path('../../lib', __dir__))
require 'liquid'

# --- Snippets (as if they lived in the snippets directory) -----------------

SNIPPETS = {
  # The inner snippet: a single card. The caller controls the action area via
  # the `actions` slot; when no slot is supplied a default action is rendered.
  'mail_card' => [
    '+--------------------------------+',
    '| {{ title }}',
    '| {{ message.preview }}',
    '| {% slot actions %}[ mark as read ]{% endslot %}',
    "+--------------------------------+\n",
  ].join("\n"),

  # The outer snippet: a titled list rendering one card per message. It
  # supplies no slots of its own, so the caller's `actions` slot is forwarded
  # to every nested mail_card rendering. A blank line separates the cards.
  'mail_list' => "Mailbox: {{ title }}\n" \
                 "{% render 'mail_card' for messages as message, title: title %}{% endrender %}",
}.freeze

# --- Caller template --------------------------------------------------------

TEMPLATE = '{% render "mail_list", messages: messages, title: "Inbox" %}' \
  '{% slot actions %}' \
  '{% if message.unread %}[ read: {{ message.preview }} ]{% else %}[ archive: {{ message.preview }} ]{% endif %}' \
  '{% endslot %}{% endrender %}'

# --- Data -------------------------------------------------------------------

MESSAGES = [
  { 'unread' => true,  'preview' => 'Meeting moved to 3pm' },
  { 'unread' => false, 'preview' => 'Your invoice is paid'  },
].freeze

class SnippetFileSystem
  def initialize(snippets)
    @snippets = snippets
  end

  def read_template_file(name)
    @snippets.fetch(name)
  end
end

file_system = SnippetFileSystem.new(SNIPPETS)
environment = Liquid::Environment.build(file_system: file_system)

output = Liquid::Template.parse(TEMPLATE, environment: environment).render!(
  { 'messages' => MESSAGES },
  registers: { file_system: file_system },
)

puts output

# Expected output:
#
#   Mailbox: Inbox
#   +--------------------------------+
#   | Inbox
#   | Meeting moved to 3pm
#   | [ read: Meeting moved to 3pm ]
#   +--------------------------------+
#   +--------------------------------+
#   | Inbox
#   | Your invoice is paid
#   | [ archive: Your invoice is paid ]
#   +--------------------------------+
