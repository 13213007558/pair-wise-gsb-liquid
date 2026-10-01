# frozen_string_literal: true

module Liquid
  module Provenance
    # Exact byte-level mappings for a number of standard filters. Every mapper
    # receives
    #   (input_string, input_spans, output_string, evaluated_args, arg_expressions, site)
    # and returns spans relative to the output string, or nil when an exact
    # mapping cannot be computed (the tracker then falls back to a coarse
    # whole-output dependency).
    #
    # Mappers verify their assumptions against the actual filter output and
    # bail out (nil) on any mismatch, so a custom filter replacing a standard
    # one never produces a fabricated mapping.
    module StandardFilterMappers
      class << self
        # upcase / downcase / capitalize: per-character transforms. Exact when
        # the per-character transform reproduces the filter output and every
        # character is fully covered by exactly one input span.
        # `char_transform` receives (char, index).
        def case_mapper(filter_name, &char_transform)
          lambda do |input, spans, output, _args, _raw_args, _site|
            transformed = input.each_char.with_index.map { |char, i| char_transform.call(char, i) }
            next nil unless transformed.join == output

            result  = []
            in_pos  = 0
            out_pos = 0
            mapping_ok = true

            input.each_char.with_index do |char, index|
              in_len  = char.bytesize
              out_len = transformed[index].bytesize
              covering = spans.select { |span| span.start < in_pos + in_len && span.end > in_pos }

              unless covering.length == 1 && covering[0].start <= in_pos && covering[0].end >= in_pos + in_len
                mapping_ok = false
                break
              end

              span   = covering[0]
              source = case_map_source(span, in_pos, in_len)
              if source.nil?
                mapping_ok = false
                break
              end

              Provenance.push_span(result, Span.new(
                out_pos,
                out_pos + out_len,
                [source],
                span.filters + [filter_name],
                span.exact?,
              ))

              in_pos  += in_len
              out_pos += out_len
            end

            mapping_ok ? result : nil
          end
        end

        # Computes the source for a single character of the input that is
        # fully covered by `span`. Returns nil when the offset within the
        # source value cannot be determined exactly.
        def case_map_source(span, in_pos, in_len)
          sources = span.sources
          return nil unless sources.length == 1

          source = sources[0]
          range  = source.input_range
          return source if range.nil?

          if range.size == span.length
            shift = in_pos - span.start
            source.with_input_range((range.begin + shift)...(range.begin + shift + in_len))
          elsif span.length == in_len && span.start == in_pos
            # The whole span maps to this one character (e.g. a previous
            # case conversion changed the byte length).
            source
          end
        end

        # strip / lstrip / rstrip: whitespace removal only shifts and clips.
        def strip_mapper(filter_name, leading, trailing)
          lambda do |input, spans, output, _args, _raw_args, _site|
            offset = leading ? input.bytesize - input.lstrip.bytesize : 0
            limit  = trailing ? input.rstrip.bytesize : input.bytesize
            next nil unless limit >= offset && input.byteslice(offset...limit) == output

            Provenance.clip_spans(spans, offset, limit - offset, filter_name)
          end
        end
      end
    end

    register_filter_mapper('upcase', &StandardFilterMappers.case_mapper('upcase') { |char, _i| char.upcase })
    register_filter_mapper('downcase', &StandardFilterMappers.case_mapper('downcase') { |char, _i| char.downcase })
    register_filter_mapper('capitalize',
      &StandardFilterMappers.case_mapper('capitalize') { |char, i| i.zero? ? char.upcase : char.downcase })

    register_filter_mapper('strip', &StandardFilterMappers.strip_mapper('strip', true, true))
    register_filter_mapper('lstrip', &StandardFilterMappers.strip_mapper('lstrip', true, false))
    register_filter_mapper('rstrip', &StandardFilterMappers.strip_mapper('rstrip', false, true))

    register_filter_mapper('append') do |input, spans, output, args, raw_args, site|
      suffix = args[0]
      suffix_str = suffix.is_a?(String) ? suffix : Utils.to_s(suffix)
      next nil unless output.bytesize == input.bytesize + suffix_str.bytesize &&
        output.start_with?(input) && output.end_with?(suffix_str)

      result = []
      spans.each { |span| Provenance.push_span(result, span.with_filter('append')) }
      if (arg_spans = Provenance.argument_spans(suffix_str, raw_args[0], site))
        arg_spans.each { |span| Provenance.push_span(result, span.shifted(input.bytesize)) }
      end
      result
    end

    register_filter_mapper('prepend') do |input, spans, output, args, raw_args, site|
      prefix = args[0]
      prefix_str = prefix.is_a?(String) ? prefix : Utils.to_s(prefix)
      next nil unless output.bytesize == input.bytesize + prefix_str.bytesize &&
        output.start_with?(prefix_str) && output.end_with?(input)

      result = []
      if (arg_spans = Provenance.argument_spans(prefix_str, raw_args[0], site))
        arg_spans.each { |span| Provenance.push_span(result, span) }
      end
      spans.each { |span| Provenance.push_span(result, span.with_filter('prepend').shifted(prefix_str.bytesize)) }
      result
    end

    register_filter_mapper('truncate') do |input, spans, output, args, raw_args, site|
      length = args[0] ? Utils.to_integer(args[0]) : 50
      truncation = args[1] ? Utils.to_s(args[1]) : '...'

      if input.length <= length
        next output == input ? spans.map { |span| span.with_filter('truncate') } : nil
      end

      keep = length - truncation.length
      keep = 0 if keep.negative?
      kept = input[0...keep]
      next nil unless kept + truncation == output

      kept_bytes = kept.bytesize
      result = Provenance.clip_spans(spans, 0, kept_bytes, 'truncate')
      unless truncation.empty?
        source = site.derive(variable: args[1] ? Provenance.describe_expression(raw_args[1]) : '...'.inspect)
        result << Span.new(kept_bytes, output.bytesize, [source], [], true)
      end
      result
    end

    register_filter_mapper('slice') do |input, spans, output, args, _raw_args, _site|
      offset = Utils.to_integer(args[0])
      length = args[1] ? Utils.to_integer(args[1]) : 1

      sliced = begin
        input.slice(offset, length)
      rescue RangeError
        nil
      end
      sliced ||= ''
      next nil unless sliced == output
      next [] if sliced.empty?

      char_offset = offset.negative? ? input.length + offset : offset
      next nil if char_offset.negative? || char_offset > input.length

      byte_offset = input[0...char_offset].bytesize
      Provenance.clip_spans(spans, byte_offset, sliced.bytesize, 'slice')
    end

    register_filter_mapper('default') do |input, spans, output, args, raw_args, site|
      if output.equal?(input)
        spans.map { |span| span.with_filter('default') }
      elsif output == Utils.to_s(args[0]) && (arg_spans = Provenance.argument_spans(args[0], raw_args[0], site))
        arg_spans
      end
    end
  end
end
