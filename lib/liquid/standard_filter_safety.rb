# frozen_string_literal: true

module Liquid
  # Auto-escape safety categories for the built in {StandardFilters}. Filters
  # not listed here produce untrusted output when auto-escaping is enabled and
  # are therefore escaped again if rendered into HTML.
  {
    # Explicitly escape: safe as body text and in quoted attributes.
    'escape'            => :escape,
    'h'                 => :escape,
    'escape_once'       => :escape,
    # Percent encoding is safe in every interpolation context.
    'url_encode'        => :url,
    # Emits trusted <br /> markup derived from the input.
    'newline_to_br'     => :html_markup,
    # Pure transforms of the input string that cannot introduce markup. Case
    # changing filters are deliberately excluded: upcasing an already escaped
    # string would corrupt its entities (&quot; -> &QUOT;), so their output is
    # treated as untrusted and escaped again at the output position (which
    # yields the correct result for the common `value | upcase` chain).
    'strip'             => :preserve,
    'lstrip'            => :preserve,
    'rstrip'            => :preserve,
    'strip_newlines'    => :preserve,
    'slice'             => :preserve,
    # Preserve trust only while the fragments they combine are trusted too.
    'append'            => :preserve_args,
    'prepend'           => :preserve_args,
    'replace'           => :preserve_args,
    'replace_first'     => :preserve_args,
    'replace_last'      => :preserve_args,
    'remove'            => :preserve_args,
    'remove_first'      => :preserve_args,
    'remove_last'       => :preserve_args,
    'truncate'          => :preserve_args,
    'truncatewords'     => :preserve_args,
  }.each do |filter_name, category|
    StrainerTemplate.safe_filter(filter_name, category)
  end
end
