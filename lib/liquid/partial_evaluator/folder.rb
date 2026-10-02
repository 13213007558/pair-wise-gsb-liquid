# frozen_string_literal: true

module Liquid
  class PartialEvaluator
    # Token-stream engine behind PartialEvaluator#evaluate.
    #
    # The folder walks the tokenized template once, mirroring Liquid's parse
    # time whitespace handling, and rewrites it into residual source:
    #
    # * statically evaluable {{ }} / echo / assign / capture / if / unless /
    #   case / for constructs are folded,
    # * everything else is copied through verbatim so it renders (and fails)
    #   exactly as it would in the original template.
    #
    # @api private
    class Folder
      # Sentinel for "value cannot be known at preprocessing time".
      UNKNOWN = Object.new.freeze

      # An empty raw block renders nothing but occupies a node slot, so it
      # can stand in for removed tags where Liquid's parse-time whitespace
      # trimming depends on node positions.
      GUARD = "{% raw %}{% endraw %}".freeze

      BLOCK_TAGS = %w[if unless case for capture tablerow ifchanged].freeze
      COMMAND_METHODS = VariableLookup::COMMAND_METHODS
      DASH = "-".ord

      Token = Struct.new(:text, :line, :type, :tag_name, :markup, :left_dash, :right_dash) do
        def left_dash?
          left_dash
        end

        def right_dash?
          right_dash
        end
      end

      def initialize(evaluator, source, static_assigns)
        @evaluator     = evaluator
        @parse_context = Liquid::ParseContext.new(evaluator.parse_options)
        @parse_context.partial = false
        @tokens        = tokenize(source)

        @scopes = [{}]
        @envs   = [static_assigns]

        @pending_lstrip        = false
        @prev_kept_right_dash  = false
        @last_node_was_markup  = false
        @suppress_left_dash    = false

        @preserved    = []
        @folded       = { variables: 0, tags: 0 }
        @spec_stack   = []
        @unroll_stack = []
        @pinned_names = compute_pinned_names

        @condition_context = Liquid::Context.build(environment: evaluator.environment)
        @strainer          = evaluator.environment.create_strainer(@condition_context)
      end

      def run
        segments = []
        fold_sequence(segments, 0, [], @tokens.length)

        source = +""
        segments.each { |segment| source << segment[1] }

        Result.new(
          source: source,
          preserved: @preserved.uniq,
          folded: @folded,
          parse_options: @evaluator.parse_options,
        )
      end

      private

      # --- tokenization ---------------------------------------------------

      def tokenize(source)
        tokenizer = @parse_context.new_tokenizer(source, start_line_number: 1)
        tokens    = []

        loop do
          line = tokenizer.line_number
          text = tokenizer.shift
          break unless text
          next if text.empty?

          tokens << build_token(text, line)
        end

        tokens
      end

      def build_token(text, line)
        if text.start_with?(BlockBody::VARSTART)
          match = BlockBody::ContentOfVariable.match(text)
          raise Liquid::SyntaxError, "Variable termination was not found" unless match

          Token.new(text, line, :variable, nil, match[1], dash?(text, 2), dash?(text, -3))
        elsif text.start_with?(BlockBody::TAGSTART)
          match = BlockBody::FullToken.match(text)
          raise Liquid::SyntaxError, "Tag termination was not found" unless match

          Token.new(text, line, :tag, match[2], match[4], dash?(text, 2), dash?(text, -3))
        else
          Token.new(text, line, :text, nil, nil, false, false)
        end
      end

      def dash?(text, index)
        text.getbyte(index) == DASH
      end

      # --- segment output & whitespace control -----------------------------
      #
      # Segments are [type, string] pairs. Types:
      #   :text   - template text (a String node at residual parse time)
      #   :folded - folded output (text at residual parse, but a non-String
      #             node in the original parse)
      #   :markup - kept tags/variables and guards (tag nodes at residual
      #             parse time)
      #
      # Liquid applies whitespace control at parse time against the previous
      # *String node*; the type tracking above reproduces that even when
      # folding changed node kinds.

      def append_text(segments, text)
        @suppress_left_dash = false
        text = text.lstrip if consume_pending_lstrip
        @prev_kept_right_dash = false unless text.strip.empty?
        return if text.empty?

        segments << [:text, text]
        @last_node_was_markup = false
      end

      def keep_token(segments, token)
        # A kept token at the start of a spliced body must not let its
        # whitespace-control dash reach back across the splice point; in the
        # original parse the body nodelist was still empty at that position.
        segments << [:markup, GUARD] if @suppress_left_dash && token.left_dash?
        @suppress_left_dash = false
        segments << [:markup, token.text]
        @pending_lstrip       = token.right_dash?
        @prev_kept_right_dash = token.right_dash?
        @last_node_was_markup = true
      end

      def remove_token(segments, token)
        rstrip_last_text(segments) if token.left_dash? && !@suppress_left_dash
        @suppress_left_dash     = false
        @pending_lstrip       = token.right_dash?
        @prev_kept_right_dash = false
        @last_node_was_markup = true
      end

      # Drops a tag that renders nothing (assign, capture, ...), leaving a
      # guard behind when neighbouring whitespace control would otherwise
      # change meaning.
      def drop_tag_node(segments, token, index)
        guard = @prev_kept_right_dash || trim_reaches_back?(index + 1)
        remove_token(segments, token)
        segments << [:markup, GUARD] if guard
      end

      def rstrip_last_text(segments)
        return if @last_node_was_markup

        last = segments.last
        return unless last && last[0] == :text

        stripped = last[1].rstrip
        if stripped.empty?
          segments.pop
        else
          last[1] = stripped
        end
      end

      def consume_pending_lstrip
        pending = @pending_lstrip
        @pending_lstrip = false
        pending
      end

      # Would parse-time whitespace trimming of a following token reach back
      # across only-whitespace text to the current position?
      def trim_reaches_back?(index)
        cursor = index
        while cursor < @tokens.length
          token = @tokens[cursor]
          if token.type == :text
            return false unless token.text.strip.empty?

            cursor += 1
          else
            return token.left_dash?
          end
        end
        false
      end

      def residual_string?(segment)
        segment[0] != :markup
      end

      # Tag tokens that stay blank? when kept verbatim.
      BLANK_KEPT_TAGS = %w[assign capture comment inline_comment # raw doc endraw enddoc endcomment].freeze

      # Would the folded segments parse as a blank? block body?
      def segments_all_blank?(segments)
        segments.all? do |segment|
          case segment[0]
          when :markup
            text = segment[1]
            next true if text == GUARD

            match = BlockBody::FullToken.match(text)
            match ? BLANK_KEPT_TAGS.include?(match[2]) : false
          else
            segment[1].strip.empty?
          end
        end
      end

      # Folds the body of a preserved construct. When folding removed every
      # non-blank node, a blank-body placeholder keeps the body's blank?
      # (and therefore remove_blank_strings and error suppression behavior)
      # identical to the original.
      def fold_preserved_body(segments, body_start, body_end, boundary_token)
        local = []
        fold_sequence(local, body_start, [], body_end)

        if !range_blank?(body_start, body_end) && segments_all_blank?(local)
          rstrip_last_text(local) if boundary_token.left_dash?
          local << [:markup, "{{ nil }}"]
          @last_node_was_markup = true
        end

        segments.concat(local)
      end

      def trim_state
        [@pending_lstrip, @prev_kept_right_dash, @last_node_was_markup]
      end

      def restore_trim_state(state)
        @pending_lstrip, @prev_kept_right_dash, @last_node_was_markup = *state
      end

      # --- structural scanning ---------------------------------------------

      # Index of the next tag token whose name is in +terminators+, skipping
      # over balanced nested constructs.
      def skip_to(index, terminators)
        cursor = index
        while cursor < @tokens.length
          token = @tokens[cursor]
          if token.type == :tag
            return cursor if terminators.include?(token.tag_name)

            cursor = skip_construct(cursor)
          else
            cursor += 1
          end
        end
        raise Liquid::SyntaxError, "tag was never closed"
      end

      # Index just past the construct starting at +index+ (a tag token).
      def skip_construct(index)
        token = @tokens[index]
        return index + 1 unless token.type == :tag

        name = token.tag_name
        case name
        when "raw" then skip_text_block(index + 1, "endraw", nil)
        when "comment" then skip_text_block(index + 1, "endcomment", "comment")
        when "doc" then skip_text_block(index + 1, "enddoc", nil)
        when *BLOCK_TAGS then skip_structural_block(index + 1, "end#{name}", name)
        else
          klass = @evaluator.environment.tag_for_name(name)
          if klass && klass <= Liquid::Block
            skip_structural_block(index + 1, "end#{name}", name)
          else
            index + 1
          end
        end
      end

      # raw/comment/doc bodies are not parsed as tags; only their own
      # delimiter (and same-name nesting for comment) matters.
      def skip_text_block(index, delimiter, nest_name)
        depth  = 1
        cursor = index
        while cursor < @tokens.length
          token = @tokens[cursor]
          if token.type == :tag
            if token.tag_name == delimiter
              depth -= 1
              return cursor + 1 if depth.zero?
            elsif nest_name && token.tag_name == nest_name
              depth += 1
            end
          end
          cursor += 1
        end
        raise Liquid::SyntaxError, "tag was never closed"
      end

      def skip_structural_block(index, delimiter, nest_name)
        depth  = 1
        cursor = index
        while cursor < @tokens.length
          token = @tokens[cursor]
          if token.type == :tag
            if token.tag_name == delimiter
              depth -= 1
              return cursor + 1 if depth.zero?
            elsif token.tag_name == nest_name
              depth += 1
              cursor += 1
            else
              cursor = skip_construct(cursor)
            end
          else
            cursor += 1
          end
        end
        raise Liquid::SyntaxError, "tag was never closed"
      end

      # --- blankness (mirrors BlockBody#blank? / remove_blank_strings) --------

      # True when every token in [start, limit) is blank per Liquid's parse
      # time blank? rules.
      def range_blank?(start, limit)
        cursor = start
        while cursor < limit
          token = @tokens[cursor]
          case token.type
          when :text
            return false unless token.text.strip.empty?

            cursor += 1
          when :variable
            return false
          else
            blank, cursor = tag_blankness(cursor)
            return false unless blank
          end
        end
        true
      end

      # Returns [blank, next_index] for the tag token at +index+.
      def tag_blankness(index)
        token = @tokens[index]
        case token.tag_name
        when "assign", "inline_comment", "#"
          [true, index + 1]
        when "capture", "comment"
          [true, skip_construct(index)]
        when "raw", "doc"
          # Blank only when the body is completely empty.
          [skip_construct(index) == index + 2, skip_construct(index)]
        when "if", "unless"
          blank_conditional?(index, token.tag_name == "if" ? "endif" : "endunless")
        when "case"
          blank_case?(index)
        when "for", "tablerow"
          blank_loop?(index, "end#{token.tag_name}")
        when "ifchanged"
          fin = skip_construct(index)
          [range_blank?(index + 1, fin - 1), fin]
        else
          klass = @evaluator.environment.tag_for_name(token.tag_name)
          if klass && klass <= Liquid::Block
            fin = skip_construct(index)
            [range_blank?(index + 1, fin - 1), fin]
          else
            [false, index + 1]
          end
        end
      end

      def blank_conditional?(index, end_name)
        terms   = ["elsif", "else", end_name]
        blank   = true
        cursor  = index + 1
        body_end = index
        loop do
          body_end = skip_to(cursor, terms)
          blank &&= range_blank?(cursor, body_end)
          break if @tokens[body_end].tag_name == end_name

          cursor = body_end + 1
        end
        [blank, body_end + 1]
      end

      def blank_case?(index)
        first_branch = skip_to(index + 1, ["when", "else", "endcase"])
        blank = range_blank?(index + 1, first_branch)
        cursor = first_branch
        while @tokens[cursor].tag_name != "endcase"
          body_end = skip_to(cursor + 1, ["when", "else", "endcase"])
          blank &&= range_blank?(cursor + 1, body_end)
          cursor = body_end
        end
        [blank, cursor + 1]
      end

      def blank_loop?(index, end_name)
        body_end = skip_to(index + 1, ["else", end_name])
        blank = range_blank?(index + 1, body_end)
        if @tokens[body_end].tag_name == "else"
          else_end = skip_to(body_end + 1, [end_name])
          blank &&= range_blank?(body_end + 1, else_end)
          return [blank, else_end + 1]
        end
        [blank, body_end + 1]
      end

      # --- main dispatch ----------------------------------------------------

      # Folds tokens from +index+ up to +limit+ into +segments+. Stops before
      # a tag whose name is in +terminators+ and returns its index.
      # When +blank_body+ is set, whitespace-only text is dropped, mirroring
      # BlockBody#remove_blank_strings for blank if/for/case bodies.
      def fold_sequence(segments, index, terminators, limit, blank_body = false)
        cursor = index
        while cursor < limit
          token = @tokens[cursor]
          case token.type
          when :text
            if blank_body && token.text.strip.empty?
              consume_pending_lstrip
            else
              append_text(segments, token.text)
            end
            cursor += 1
          when :variable
            fold_variable_token(segments, token, cursor)
            cursor += 1
          else
            return cursor if !terminators.empty? && terminators.include?(token.tag_name)

            cursor = dispatch_tag(segments, token, cursor)
          end
        end
        cursor
      end

      def dispatch_tag(segments, token, index)
        case token.tag_name
        when "assign" then handle_assign(segments, token, index)
        when "capture" then handle_capture(segments, token, index)
        when "if" then handle_conditional(segments, token, index, :if)
        when "unless" then handle_conditional(segments, token, index, :unless)
        when "case" then handle_case(segments, token, index)
        when "for" then handle_for(segments, token, index)
        when "echo" then handle_echo(segments, token, index)
        when "raw"
          copy_verbatim_block(segments, token, index, "endraw", nil, false)
        when "comment"
          copy_verbatim_block(segments, token, index, "endcomment", "comment", false)
        when "doc"
          copy_verbatim_block(segments, token, index, "enddoc", nil, false)
        when "tablerow"
          record_preserved(:tag, token, :unsupported_tag, { tag: "tablerow" })
          copy_verbatim_block(segments, token, index, "endtablerow", "tablerow", true)
        when "ifchanged"
          record_preserved(:tag, token, :stateful_tag, { tag: "ifchanged" })
          keep_token(segments, token)
          body_end = skip_to(index + 1, ["endifchanged"])
          fold_preserved_body(segments, index + 1, body_end, @tokens[body_end])
          keep_token(segments, @tokens[body_end])
          body_end + 1
        when "include"
          record_preserved(:tag, token, :template_include, { tag: token.tag_name })
          check_unroll_conflict_text(token.text)
          # Included templates share the caller's context and may reassign
          # anything, so nothing is statically known afterwards.
          invalidate_all_static
          keep_token(segments, token)
          index + 1
        when "render"
          record_preserved(:tag, token, :template_include, { tag: token.tag_name })
          check_unroll_conflict_text(token.text)
          keep_token(segments, token)
          index + 1
        when "cycle"
          record_preserved(:tag, token, :stateful_tag, { tag: "cycle" })
          check_unroll_conflict_text(token.text)
          keep_token(segments, token)
          index + 1
        when "increment", "decrement"
          record_preserved(:tag, token, :stateful_tag, { tag: token.tag_name })
          @envs[0][token.markup.to_s.strip] = UNKNOWN
          keep_token(segments, token)
          index + 1
        when "break", "continue"
          record_preserved(:tag, token, :stateful_tag, { tag: token.tag_name })
          keep_token(segments, token)
          index + 1
        when "liquid"
          record_preserved(:tag, token, :liquid_tag, {})
          check_unroll_conflict_text(token.text)
          invalidate_liquid_tag_assigns(token.markup)
          keep_token(segments, token)
          index + 1
        when "inline_comment", "#"
          keep_token(segments, token)
          index + 1
        else
          handle_custom_tag(segments, token, index)
        end
      end

      def handle_custom_tag(segments, token, index)
        klass = @evaluator.environment.tag_for_name(token.tag_name)
        unless klass
          raise Liquid::SyntaxError,
            @parse_context.locale.t("errors.syntax.unknown_tag", tag: token.tag_name)
        end

        record_preserved(:tag, token, :custom_tag, { tag: token.tag_name })

        if klass <= Liquid::Block
          copy_verbatim_block(segments, token, index, "end#{token.tag_name}", token.tag_name, true)
        else
          check_unroll_conflict_text(token.text)
          keep_token(segments, token)
          index + 1
        end
      end

      # Copies a block construct verbatim (raw/comment/doc/tablerow/ifchanged
      # and custom blocks). When +check_conflicts+ is set, kept markup is
      # screened against in-progress loop unrolling.
      def copy_verbatim_block(segments, token, index, delimiter, nest_name, check_conflicts)
        keep_token(segments, token)
        depth  = 1
        cursor = index + 1

        while cursor < @tokens.length
          current = @tokens[cursor]
          if current.type == :tag && current.tag_name == delimiter
            depth -= 1
            keep_token(segments, current)
            cursor += 1
            return cursor if depth.zero?

            next
          elsif nest_name && current.type == :tag && current.tag_name == nest_name
            depth += 1
          end

          copy_token_verbatim(segments, current, check_conflicts)
          cursor += 1
        end

        raise Liquid::SyntaxError, "tag was never closed"
      end

      def copy_token_verbatim(segments, token, check_conflicts)
        if token.type == :text
          append_text(segments, token.text)
        else
          check_unroll_conflict_text(token.text) if check_conflicts
          keep_token(segments, token)
        end
      end

      # --- static values ----------------------------------------------------

      def plain_data?(value, seen = {})
        case value
        when nil, true, false, Integer, Float, String, Symbol
          true
        when BigDecimal
          true
        when Range
          value.instance_of?(Range) &&
            plain_data?(value.begin, seen) && plain_data?(value.end, seen)
        when Array
          return false unless value.instance_of?(Array)
          return false if seen[value.object_id]

          seen[value.object_id] = true
          value.all? { |element| plain_data?(element, seen) }
        when Hash
          return false unless value.instance_of?(Hash)
          return false if seen[value.object_id]

          seen[value.object_id] = true
          value.all? { |key, element| plain_data?(key, seen) && plain_data?(element, seen) }
        else
          false
        end
      end

      def liquid_truthy?(value)
        !value.nil? && value != false
      end

      def static_find(name)
        @scopes.each { |scope| return [true, scope[name]] if scope.key?(name) }
        @envs.each { |env| return [true, env[name]] if env.key?(name) }
        [false, nil]
      end

      def set_static(name, value)
        @scopes.last[name] = value
      end

      def speculative?
        !@spec_stack.empty?
      end

      def invalidate_speculative(names)
        names.each { |name| set_static(name, UNKNOWN) }
      end

      def pinned?(name)
        @pinned_names.include?(name)
      end

      # Names whose statically folded assignment must remain in the residual
      # template because the variable may be (re)assigned at render time in a
      # way the folder cannot track: assignment inside a block that might not
      # fold, or increment/decrement counters (which live outside the assign
      # scope but become visible when no assign shadows them).
      def compute_pinned_names
        pinned = []
        depth  = 0
        cursor = 0
        # {% include %} shares the caller's context, so any variable it
        # might reassign must keep its assignment in the residual template.
        pin_all_assigns = @tokens.any? { |token| token.type == :tag && token.tag_name == "include" }

        while cursor < @tokens.length
          token = @tokens[cursor]
          if token.type == :tag
            case token.tag_name
            when "assign"
              pinned << assign_target(token.markup) if depth.positive? || pin_all_assigns
            when "capture"
              pinned << capture_target(token.markup) if depth.positive? || pin_all_assigns
              depth += 1
            when "increment", "decrement"
              pinned << token.markup.to_s.strip
            when "liquid"
              pinned.concat(liquid_tag_assignments(token.markup).flatten) if depth.positive? || pin_all_assigns
            when "raw", "comment", "doc"
              cursor = skip_construct(cursor)
              next
            when *BLOCK_TAGS
              depth += 1
            else
              if token.tag_name.start_with?("end")
                depth -= 1 if depth.positive?
              else
                klass = @evaluator.environment.tag_for_name(token.tag_name)
                depth += 1 if klass && klass <= Liquid::Block
              end
            end
          end
          cursor += 1
        end

        pinned
      end

      def assign_target(markup)
        markup =~ Assign::Syntax ? Regexp.last_match(1) : nil
      end

      def capture_target(markup)
        markup =~ Capture::Syntax ? Regexp.last_match(1) : nil
      end

      # Variable names a {% liquid %} tag assigns to, as
      # [scope_assignments, counter_assignments].
      def liquid_tag_assignments(markup)
        scope_names   = []
        counter_names = []
        markup.to_s.each_line do |line|
          case line
          when /^\s*assign\s+(#{VariableSignature}+)\s*=/
            scope_names << Regexp.last_match(1)
          when /^\s*capture\s+(#{VariableSignature}+)\s*(?:$|\s)/
            scope_names << Regexp.last_match(1)
          when /^\s*(?:increment|decrement)\s+(#{VariableSignature}+)\s*(?:$|\s)/
            counter_names << Regexp.last_match(1)
          end
        end
        [scope_names, counter_names]
      end

      def invalidate_liquid_tag_assigns(markup)
        scope_names, counter_names = liquid_tag_assignments(markup)
        scope_names.each { |name| set_static(name, UNKNOWN) }
        counter_names.each { |name| @envs[0][name] = UNKNOWN }
      end

      # {% include %} shares the caller's context, so the included template
      # may reassign anything. Everything known becomes unknown.
      def invalidate_all_static
        @scopes.each { |scope| scope.each_key { |key| scope[key] = UNKNOWN } }
        @envs.each { |env| env.each_key { |key| env[key] = UNKNOWN } }
      end

      # --- static expression evaluation --------------------------------------
      #
      # Returns a plain-data value, or UNKNOWN. Unknown root variable names
      # are collected into +collector+ for diagnostics and loop-unroll safety.
      # Drop methods, Procs and arbitrary objects are never called.

      def eval_expr(expr, collector)
        case expr
        when nil, true, false, Integer, Float, String
          expr
        when Range
          plain_data?(expr) ? expr : UNKNOWN
        when VariableLookup
          eval_variable_lookup(expr, collector)
        when RangeLookup
          eval_range_lookup(expr, collector)
        when Condition::MethodLiteral
          expr
        else
          plain_data?(expr) ? expr : UNKNOWN
        end
      end

      def eval_range_lookup(expr, collector)
        start_value = eval_expr(expr.start_obj, collector)
        return UNKNOWN if start_value.equal?(UNKNOWN)

        end_value = eval_expr(expr.end_obj, collector)
        return UNKNOWN if end_value.equal?(UNKNOWN)

        range_to_integer(start_value)..range_to_integer(end_value)
      rescue ::StandardError, Liquid::Error
        UNKNOWN
      end

      def range_to_integer(input)
        case input
        when Integer then input
        when NilClass, String then input.to_i
        else Utils.to_integer(input)
        end
      end

      def eval_variable_lookup(lookup, collector)
        name = lookup.name
        name = eval_expr(name, collector) unless name.is_a?(String)
        return UNKNOWN unless name.is_a?(String)

        found, object = static_find(name)
        if !found || object.equal?(UNKNOWN)
          collector << name
          return UNKNOWN
        end

        lookup.lookups.each_index do |index|
          key = lookup.lookups[index]
          key = eval_expr(key, collector) unless key.is_a?(String)
          return UNKNOWN if key.equal?(UNKNOWN)

          key = Utils.to_liquid_value(key)
          ok, object = static_traverse(object, key, lookup.lookup_command?(index))
          unless ok
            collector << name
            return UNKNOWN
          end
          if object.equal?(UNKNOWN)
            collector << name
            return UNKNOWN
          end
        end

        if plain_data?(object)
          object
        else
          collector << name
          UNKNOWN
        end
      end

      def static_hash?(object)
        object.instance_of?(Hash) || object.is_a?(StaticForloopHash)
      end

      # Mirrors VariableLookup#evaluate for plain data. Returns [ok, value];
      # ok is false when evaluation is impossible without running user code
      # or would raise at render time (strict variables).
      def static_traverse(object, key, command)
        if static_hash?(object) && object.key?(key)
          value = object[key]
          # Context#lookup_and_evaluate would call a stored Proc; never do
          # that during preprocessing.
          return [false, nil] if value.is_a?(Proc)

          return [true, value]
        end

        if object.instance_of?(Array) && key.is_a?(Integer)
          if @evaluator.strict_variables? && (key >= object.length || key < -object.length)
            return [false, nil]
          end

          return [true, object[key]]
        end

        if command
          if object.instance_of?(String)
            return [true, object.size] if key == "size"
            return [true, object[0] || ""] if key == "first"
            return [true, object[-1] || ""] if key == "last"
          end
          if (object.instance_of?(Array) || static_hash?(object)) && COMMAND_METHODS.include?(key)
            return [true, object.send(key)]
          end
          if COMMAND_METHODS.include?(key) &&
            (object.instance_of?(Integer) || object.instance_of?(Symbol) || object.instance_of?(Range)) &&
            object.respond_to?(key)
            return [true, object.send(key)]
          end
        end

        # Anything that is not plain data (Drops, Procs, arbitrary objects)
        # would require calling user code to resolve the lookup.
        return [false, nil] unless plain_traversable_miss?(object)

        # Missing lookup on plain data: renders as nil, or raises
        # UndefinedVariable under strict_variables. Keep it for render time
        # in the latter case.
        [!@evaluator.strict_variables?, nil]
      end

      # Objects whose missed lookup renders as nil without running any user
      # code (mirrors VariableLookup#evaluate's respond_to? gates).
      def plain_traversable_miss?(object)
        case object
        when nil, true, false, Integer, Float, String, Symbol, BigDecimal
          true
        when Range
          object.instance_of?(Range)
        when Array
          object.instance_of?(Array)
        when Hash
          object.instance_of?(Hash) || object.is_a?(StaticForloopHash)
        else
          false
        end
      end

      # --- conditions ---------------------------------------------------------

      def eval_condition_operand(markup, collector)
        operand = Condition.parse_expression(@parse_context, markup && markup.strip, safe: true)
        if operand.is_a?(Condition::MethodLiteral)
          operand
        else
          eval_expr(operand, collector)
        end
      end

      def eval_comparison(left_markup, operator, right_markup, collector)
        left = eval_condition_operand(left_markup, collector)
        return UNKNOWN if left.equal?(UNKNOWN)
        return left if operator.nil?

        right = eval_condition_operand(right_markup, collector)
        return UNKNOWN if right.equal?(UNKNOWN)

        Condition.new(left, operator, right).evaluate(@condition_context)
      rescue ::StandardError, Liquid::Error
        UNKNOWN
      end

      # Mirrors If#lax_parse / Condition#evaluate for fully known operands.
      def eval_condition(markup, collector)
        expressions = markup.scan(If::ExpressionsAndOperators)
        raise Liquid::SyntaxError, @parse_context.locale.t("errors.syntax.if") if expressions.empty?

        conditions  = [condition_triple(expressions.pop)]
        relations   = []
        until expressions.empty?
          operator = expressions.pop.to_s.strip
          operand  = expressions.pop.to_s
          unless If::BOOLEAN_OPERATORS.include?(operator)
            raise Liquid::SyntaxError, @parse_context.locale.t("errors.syntax.if")
          end

          conditions.unshift(condition_triple(operand))
          relations.unshift(operator.to_sym)
        end

        result = nil
        conditions.each_with_index do |(left, operator, right), index|
          result = eval_comparison(left, operator, right, collector)
          return UNKNOWN if result.equal?(UNKNOWN)

          relation = relations[index]
          break unless relation

          truthy = liquid_truthy?(result)
          break if relation == :or && truthy
          break if relation == :and && !truthy
        end
        result
      end

      def condition_triple(markup)
        unless (match = If::Syntax.match(markup))
          raise Liquid::SyntaxError, @parse_context.locale.t("errors.syntax.if")
        end

        [match[1], match[2], match[3]]
      end

      # --- output evaluation ----------------------------------------------------

      # Evaluates a Variable (expression + filter chain). Returns
      # [:ok, value] or [:preserve, reason, details].
      def eval_output(variable)
        collector = []
        value     = eval_expr(variable.name, collector)
        return [:preserve, :unknown_variables, { variables: collector.uniq }] if value.equal?(UNKNOWN)

        variable.filters.each do |filter|
          filter_name   = filter[0]
          filter_args   = filter[1]
          filter_kwargs = filter[2]

          unless @evaluator.pure_filters.include?(filter_name)
            return [:preserve, :unregistered_filter, { filter: filter_name, variables: collector.uniq }]
          end
          unless @strainer.class.invokable?(filter_name)
            return [:preserve, :unknown_filter, { filter: filter_name }]
          end

          args = []
          filter_args.each do |arg_expr|
            arg_value = eval_expr(arg_expr, collector)
            return [:preserve, :unknown_variables, { variables: collector.uniq }] if arg_value.equal?(UNKNOWN)

            args << arg_value
          end
          if filter_kwargs
            kwargs = {}
            filter_kwargs.each do |key, kwarg_expr|
              kwarg_value = eval_expr(kwarg_expr, collector)
              return [:preserve, :unknown_variables, { variables: collector.uniq }] if kwarg_value.equal?(UNKNOWN)

              kwargs[key] = kwarg_value
            end
            args << kwargs
          end

          begin
            value = @strainer.invoke(filter_name, value, *args).to_liquid
          rescue ::StandardError => e
            # Leave it for render time so the same error is produced there.
            return [:preserve, :filter_error, { filter: filter_name, error: "#{e.class}: #{e.message}" }]
          end

          unless plain_data?(value)
            return [:preserve, :non_plain_value, { filter: filter_name }]
          end
        end

        [:ok, value]
      end

      # Mirrors Variable#render_obj_to_output for plain data.
      def output_string(value)
        case value
        when nil
          +""
        when Array
          value.map { |element| output_string(element) }.join
        else
          Utils.to_s(value)
        end
      end

      # --- diagnostics & unroll safety -------------------------------------------

      def record_preserved(kind, token, reason, details = {})
        @preserved << PreservedNode.new(
          kind: kind,
          markup: token.markup.to_s.strip,
          line_number: token.line,
          reason: reason,
          details: details,
        )

        # A kept token may reference loop-scoped variables (statically known
        # or not) that will not exist once the loop is unrolled.
        check_unroll_conflict_text(token.text)

        variables = details[:variables]
        check_unroll_conflict_vars(variables) if variables && !variables.empty?
      end

      def check_unroll_conflict_vars(variables)
        return if @unroll_stack.empty?

        @unroll_stack.each do |frame|
          frame[:conflict] = true unless (variables & frame[:names]).empty?
        end
      end

      def check_unroll_conflict_text(text)
        return if @unroll_stack.empty?

        @unroll_stack.each do |frame|
          frame[:names].each do |name|
            if text.match?(/\b#{Regexp.escape(name)}\b/)
              frame[:conflict] = true
              break
            end
          end
        end
      end

      # --- variables & simple tags ---------------------------------------------

      def fold_variable_token(segments, token, index)
        variable = Liquid::Variable.new(token.markup, @parse_context)
        status, value, details = eval_output(variable)

        if status == :ok
          if insert_folded_text(segments, output_string(value), token, index)
            @folded[:variables] += 1
          else
            keep_token(segments, token)
            record_preserved(:variable, token, :unsafe_output, {})
          end
        else
          keep_token(segments, token)
          record_preserved(:variable, token, value, details)
        end
      end

      def handle_echo(segments, token, index)
        fold_variable_token(segments, token, index)
        index + 1
      end

      # Inserts folded output in place of a variable token. Returns false
      # when the output cannot be represented safely (it would be re-parsed
      # as template syntax).
      def insert_folded_text(segments, string, token, index)
        suppress_left_dash = @suppress_left_dash
        @suppress_left_dash = false
        raw = false
        if string.empty?
          # The variable node disappears; keep a placeholder if neighbouring
          # whitespace control relied on its presence.
          needed = @prev_kept_right_dash || trim_reaches_back?(index + 1)
          rstrip_last_text(segments) if token.left_dash? && !suppress_left_dash
          @pending_lstrip       = token.right_dash?
          @prev_kept_right_dash = false
          @last_node_was_markup = true
          segments << [:markup, GUARD] if needed
          return true
        elsif string.match?(/\{[{%]/)
          # The folded text would be re-parsed as template syntax; shield it
          # inside a raw block unless that is impossible.
          return false if string.match?(/\{%-?\s*endraw/)

          raw = true
        end

        guard_before = @prev_kept_right_dash
        guard_after  = trim_reaches_back?(index + 1)

        rstrip_last_text(segments) if token.left_dash? && !suppress_left_dash
        @pending_lstrip       = token.right_dash?
        @prev_kept_right_dash = false
        @last_node_was_markup = true

        if raw
          segments << [:markup, "{% raw %}#{string}{% endraw %}"]
        else
          segments << [:markup, GUARD] if guard_before
          segments << [:folded, string]
          segments << [:markup, GUARD] if guard_after
        end
        true
      end

      def handle_assign(segments, token, index)
        match = Assign::Syntax.match(token.markup)
        raise Liquid::SyntaxError, @parse_context.locale.t("errors.syntax.assign") unless match

        to       = match[1]
        variable = Liquid::Variable.new(match[2], @parse_context)
        status, value, details = eval_output(variable)

        if status == :ok
          set_static(to, value)
          if speculative?
            @spec_stack.last << to
            check_unroll_conflict_text(token.text)
            keep_token(segments, token)
            record_preserved(:tag, token, :dynamic_scope, {})
          elsif pinned?(to)
            # The value is known, but the assignment must stay in the
            # residual template because the variable can be reassigned at
            # render time somewhere the folder cannot track.
            check_unroll_conflict_text(token.text)
            keep_token(segments, token)
            record_preserved(:tag, token, :dynamic_scope, {})
          else
            drop_tag_node(segments, token, index)
            @folded[:tags] += 1
          end
        else
          set_static(to, UNKNOWN)
          @spec_stack.last << to if speculative?
          check_unroll_conflict_text(token.text)
          keep_token(segments, token)
          record_preserved(:tag, token, value, details)
        end

        index + 1
      end

      def handle_capture(segments, token, index)
        match = Capture::Syntax.match(token.markup)
        raise Liquid::SyntaxError, @parse_context.locale.t("errors.syntax.capture") unless match

        to             = match[1]
        body_start     = index + 1
        body_end       = skip_to(body_start, ["endcapture"])
        end_token      = @tokens[body_end]

        saved_trim       = trim_state
        preserved_before = @preserved.length

        local = []
        @pending_lstrip = token.right_dash?
        fold_sequence(local, body_start, [], body_end)
        rstrip_last_text(local) if end_token.left_dash?

        captured = capture_text(local)
        if !captured.nil? && @preserved.length == preserved_before && !speculative?
          restore_trim_state(saved_trim)
          set_static(to, captured)
          if pinned?(to)
            keep_token(segments, token)
            segments.concat(local)
            keep_token(segments, end_token)
            record_preserved(:tag, token, :dynamic_scope, {})
          else
            guard = @prev_kept_right_dash || trim_reaches_back?(body_end + 1)
            remove_token(segments, token)
            @pending_lstrip = end_token.right_dash?
            segments << [:markup, GUARD] if guard
            @folded[:tags] += 1
          end
        else
          restore_trim_state(saved_trim)
          keep_token(segments, token)
          segments.concat(local)
          keep_token(segments, end_token)
          set_static(to, captured.nil? ? UNKNOWN : captured)
          if speculative?
            @spec_stack.last << to
            record_preserved(:tag, token, :dynamic_scope, {})
          end
        end

        body_end + 1
      end

      # The static capture value when every segment renders to known text,
      # or nil when something dynamic remains.
      def capture_text(segments)
        text = +""
        segments.each do |segment|
          if segment[0] == :markup
            return nil unless segment[1] == GUARD
          else
            text << segment[1]
          end
        end
        text
      end

      # --- if / unless -----------------------------------------------------------

      def handle_conditional(segments, token, index, kind)
        end_name      = kind == :if ? "endif" : "endunless"
        branch_terms  = ["elsif", "else", end_name]
        branches      = []
        cursor        = index

        loop do
          condition_token = @tokens[cursor]
          body_start      = cursor + 1
          body_end        = skip_to(body_start, branch_terms)
          branches << [condition_token, body_start, body_end]
          break if @tokens[body_end].tag_name == end_name

          cursor = body_end
        end

        end_index = branches.last[2]
        end_token = @tokens[end_index]

        collector = []
        results   = branches.map do |(condition_token, _, _)|
          condition_token.tag_name == "else" ? true : eval_condition(condition_token.markup, collector)
        end

        if results.none? { |result| result.equal?(UNKNOWN) }
          winner = nil
          results.each_with_index do |result, branch_index|
            truthy = liquid_truthy?(result)
            truthy = !truthy if kind == :unless && branch_index.zero?
            if truthy
              winner = branch_index
              break
            end
          end

          blank = branches.all? { |(_, body_start, body_end)| range_blank?(body_start, body_end) }
          fold_branch_construct(segments, token, branches, winner ? [winner] : [], end_token, end_index, blank)
          @folded[:tags] += 1
        else
          record_preserved(:tag, token, :unknown_variables, { variables: collector.uniq })
          keep_token(segments, token)
          branches.each do |(condition_token, body_start, body_end)|
            keep_token(segments, condition_token) unless condition_token.equal?(token)
            @spec_stack.push([])
            fold_preserved_body(segments, body_start, body_end, @tokens[body_end])
            invalidate_speculative(@spec_stack.pop)
          end
          keep_token(segments, end_token)
        end

        end_index + 1
      end

      # Folds a conditional-style construct away, splicing the winning
      # branch bodies into the output.
      def fold_branch_construct(segments, token, branches, winners, end_token, end_index, blank_body = false)
        guard_before = @prev_kept_right_dash
        remove_token(segments, token)
        segments << [:markup, GUARD] if guard_before
        content_start = segments.length

        winners.each do |winner|
          condition_token, body_start, body_end = branches[winner]
          local = []
          @pending_lstrip       = condition_token.right_dash?
          @prev_kept_right_dash = false
          @suppress_left_dash   = true
          fold_sequence(local, body_start, [], body_end, blank_body)
          boundary = @tokens[body_end]
          rstrip_last_text(local) if boundary.left_dash?
          # A kept token at the end of a spliced body must not let its
          # whitespace-control dash leak past the splice point; the boundary
          # tag used to overwrite the trim state in the original parse.
          local << [:markup, GUARD] if @prev_kept_right_dash
          segments.concat(local)
        end

        @pending_lstrip = end_token.right_dash?

        if segments.length == content_start
          segments << [:markup, GUARD] if !guard_before && trim_reaches_back?(end_index + 1)
        elsif trim_reaches_back?(end_index + 1) && residual_string?(segments.last)
          segments << [:markup, GUARD]
        end

        @last_node_was_markup = true
        @prev_kept_right_dash = false
      end

      # --- case -------------------------------------------------------------------

      def handle_case(segments, token, index)
        match = Case::Syntax.match(token.markup)
        raise Liquid::SyntaxError, @parse_context.locale.t("errors.syntax.case") unless match

        left_expr = @parse_context.parse_expression(match[1], safe: true)

        first_branch = skip_to(index + 1, ["when", "else", "endcase"])
        branches     = []
        cursor       = first_branch
        while @tokens[cursor].tag_name != "endcase"
          branch_token = @tokens[cursor]
          body_start   = cursor + 1
          body_end     = skip_to(body_start, ["when", "else", "endcase"])
          branches << [branch_token, body_start, body_end]
          cursor = body_end
        end
        end_index = cursor
        end_token = @tokens[end_index]

        collector = []
        left      = eval_expr(left_expr, collector)
        winners   = nil

        unless left.equal?(UNKNOWN)
          winners = []
          matched = false
          decidable = true

          branches.each_with_index do |(branch_token, _, _), branch_index|
            next if branch_token.tag_name == "else"

            parse_when_expressions(branch_token.markup).each do |when_markup|
              value = eval_condition_operand(when_markup, collector)
              if value.equal?(UNKNOWN)
                decidable = false
                break
              end

              result = begin
                Condition.new(left, "==", value).evaluate(@condition_context)
              rescue ::StandardError, Liquid::Error
                UNKNOWN
              end
              if result.equal?(UNKNOWN)
                decidable = false
                break
              end

              if liquid_truthy?(result)
                winners << branch_index
                matched = true
                break
              end
            end
            break unless decidable
          end

          if decidable && !matched
            branches.each_with_index do |(branch_token, _, _), branch_index|
              winners << branch_index if branch_token.tag_name == "else"
            end
          end
          winners = nil unless decidable
        end

        if winners
          blank = range_blank?(index + 1, first_branch) &&
            branches.all? { |(_, body_start, body_end)| range_blank?(body_start, body_end) }
          fold_branch_construct(segments, token, branches, winners, end_token, end_index, blank)
          @folded[:tags] += 1
        else
          record_preserved(:tag, token, :unknown_variables, { variables: collector.uniq })
          keep_token(segments, token)
          # Tokens between {% case %} and the first {% when %} are parsed but
          # never rendered; copy them verbatim.
          ((index + 1)...first_branch).each do |dead|
            copy_token_verbatim(segments, @tokens[dead], false)
          end
          branches.each do |(branch_token, body_start, body_end)|
            keep_token(segments, branch_token)
            @spec_stack.push([])
            fold_preserved_body(segments, body_start, body_end, @tokens[body_end])
            invalidate_speculative(@spec_stack.pop)
          end
          keep_token(segments, end_token)
        end

        end_index + 1
      end

      def parse_when_expressions(markup)
        expressions = []
        while markup
          match = Case::WhenSyntax.match(markup)
          unless match
            raise Liquid::SyntaxError, @parse_context.locale.t("errors.syntax.case_invalid_when")
          end

          expressions << match[1]
          markup = match[2]
        end
        expressions
      end

      # --- for --------------------------------------------------------------------

      def handle_for(segments, token, index)
        match = For::Syntax.match(token.markup)
        raise Liquid::SyntaxError, @parse_context.locale.t("errors.syntax.for") unless match

        variable_name = match[1]
        collection_markup = match[2]
        reversed = !match[3].nil?
        limit_markup = nil
        offset_markup = nil
        token.markup.scan(TagAttributes) do |key, value|
          limit_markup = value if key == "limit"
          offset_markup = value if key == "offset"
        end

        body_start = index + 1
        body_end   = skip_to(body_start, ["else", "endfor"])
        else_token = nil
        else_start = nil
        else_end   = nil
        if @tokens[body_end].tag_name == "else"
          else_token = @tokens[body_end]
          else_start = body_end + 1
          else_end   = skip_to(else_start, ["endfor"])
          end_index  = else_end
        else
          end_index = body_end
        end
        end_token = @tokens[end_index]

        loop_blank = range_blank?(body_start, body_end) &&
          (else_token.nil? || range_blank?(else_start, else_end))

        collector = []
        segment, cause = static_segment(
          collection_markup, limit_markup, offset_markup, reversed,
          body_start, body_end, collector
        )

        if cause.nil?
          unrolled = try_unroll_loop(
            segments, token, index, end_index, end_token, else_token,
            body_start, body_end, else_start, else_end, loop_blank,
            variable_name, collection_markup, segment
          )
          return end_index + 1 if unrolled

          cause = @last_unroll_failure || :expansion_limit
        end

        record_preserved(:tag, token, :loop_not_foldable, {
          cause: cause,
          variables: collector.uniq,
        })
        keep_token(segments, token)
        @scopes.unshift(variable_name => UNKNOWN, "forloop" => UNKNOWN)
        @spec_stack.push([])
        fold_preserved_body(segments, body_start, body_end, else_token || end_token)
        invalidate_speculative(@spec_stack.pop)
        @scopes.shift
        if else_token
          keep_token(segments, else_token)
          @spec_stack.push([])
          fold_preserved_body(segments, else_start, else_end, end_token)
          invalidate_speculative(@spec_stack.pop)
        end
        keep_token(segments, end_token)
        end_index + 1
      end

      # Computes the iteration segment for a fully static loop. Returns
      # [segment, nil] or [nil, cause].
      def static_segment(collection_markup, limit_markup, offset_markup, reversed,
        body_start, body_end, collector)
        if offset_markup && offset_markup.strip == "continue"
          return [nil, :continue_offset]
        end

        collection = eval_expr(@parse_context.parse_expression(collection_markup, safe: true), collector)
        return [nil, :dynamic_collection] if collection.equal?(UNKNOWN)

        offset_value = offset_markup ? eval_expr(@parse_context.parse_expression(offset_markup, safe: true), collector) : 0
        limit_value  = limit_markup ? eval_expr(@parse_context.parse_expression(limit_markup, safe: true), collector) : nil
        return [nil, :dynamic_attributes] if offset_value.equal?(UNKNOWN) || limit_value.equal?(UNKNOWN)

        begin
          from = offset_value.nil? ? 0 : Utils.to_integer(offset_value)
          to   = limit_value.nil? ? nil : Utils.to_integer(limit_value) + from
          segment = compute_segment(collection, from, to)
          segment.reverse! if reversed
        rescue ::StandardError, Liquid::Error
          return [nil, :invalid_collection]
        end

        return [nil, :too_large] if segment.length > @evaluator.max_unroll
        return [nil, :non_plain_items] unless segment.all? { |item| plain_data?(item) }
        return [nil, :stateful_body] if loop_hazards?(body_start, body_end)

        [segment, nil]
      end

      # Mirrors Utils.slice_collection_using_each for plain data.
      def compute_segment(collection, from, to)
        items =
          case collection
          when Array then collection
          when Range then collection.to_a
          when String then collection.empty? ? [] : [collection]
          when Hash then collection.to_a
          else []
          end

        segment = []
        items.each_with_index do |item, item_index|
          break if to && to <= item_index

          segment << item if from <= item_index
        end
        segment
      end

      # break/continue/ifchanged inside the loop body (outside nested loops)
      # make unrolling unsafe.
      def loop_hazards?(start, limit)
        cursor = start
        while cursor < limit
          token = @tokens[cursor]
          if token.type == :tag
            case token.tag_name
            when "break", "continue", "ifchanged"
              return true
            when "for", "tablerow", "raw", "comment", "doc"
              cursor = skip_construct(cursor)
              next
            end
          end
          cursor += 1
        end
        false
      end

      # Attempts to unroll a static loop. Returns true on success, false when
      # the body still depends on loop-scoped variables after folding (the
      # loop must stay so those variables exist at render time).
      def try_unroll_loop(segments, token, index, end_index, end_token, else_token,
        body_start, body_end, else_start, else_end, loop_blank,
        variable_name, collection_markup, segment)
        state = snapshot_state(segments)
        frame = { names: [variable_name, "forloop"], conflict: false }
        @unroll_stack.push(frame)

        begin
          guard_before = @prev_kept_right_dash
          remove_token(segments, token)
          segments << [:markup, GUARD] if guard_before
          content_start = segments.length

          _found, parent = static_find("forloop")
          length = segment.length

          segment.each_with_index do |item, item_index|
            forloop = StaticForloopHash.new
            forloop["name"]       = "#{variable_name}-#{collection_markup}"
            forloop["length"]     = length
            forloop["index"]      = item_index + 1
            forloop["index0"]     = item_index
            forloop["rindex"]     = length - item_index
            forloop["rindex0"]    = length - item_index - 1
            forloop["first"]      = item_index.zero?
            forloop["last"]       = item_index == length - 1
            forloop["parentloop"] = parent

            @scopes.unshift(variable_name => item, "forloop" => forloop)
            local = []
            @pending_lstrip       = token.right_dash?
            @prev_kept_right_dash = false
            @suppress_left_dash   = true
            fold_sequence(local, body_start, [], body_end, loop_blank)
            boundary = else_token || end_token
            rstrip_last_text(local) if boundary.left_dash?
            local << [:markup, GUARD] if @prev_kept_right_dash
            segments.concat(local)
            @scopes.shift

            break if frame[:conflict]
          end

          if length.zero? && else_token
            local = []
            @pending_lstrip       = else_token.right_dash?
            @prev_kept_right_dash = false
            @suppress_left_dash   = true
            fold_sequence(local, else_start, [], else_end, loop_blank)
            rstrip_last_text(local) if end_token.left_dash?
            local << [:markup, GUARD] if @prev_kept_right_dash
            segments.concat(local)
          end

          @pending_lstrip = end_token.right_dash?

          expansion = 0
          segments[content_start..-1].each { |part| expansion += part[1].length }

          if frame[:conflict]
            @last_unroll_failure = :loop_variable_escape
          elsif expansion > @evaluator.max_expansion
            @last_unroll_failure = :expansion_limit
          else
            @last_unroll_failure = nil
          end

          if @last_unroll_failure
            restore_state(state)
            return false
          end

          if segments.length == content_start
            segments << [:markup, GUARD] if !guard_before && trim_reaches_back?(end_index + 1)
          elsif trim_reaches_back?(end_index + 1) && residual_string?(segments.last)
            segments << [:markup, GUARD]
          end

          @last_node_was_markup = true
          @prev_kept_right_dash = false
          @folded[:tags] += 1
          true
        ensure
          @unroll_stack.pop
        end
      end

      def snapshot_state(segments)
        [
          segments,
          segments.length,
          @scopes.map(&:dup),
          @envs.map(&:dup),
          trim_state,
          @preserved.length,
          @folded.dup,
        ]
      end

      def restore_state(state)
        segments, segments_length, scopes, envs, trim, preserved_length, folded = *state
        segments.slice!(segments_length..-1)
        @scopes = scopes
        @envs = envs
        restore_trim_state(trim)
        @preserved.slice!(preserved_length..-1)
        @folded = folded
      end
    end
  end
end
