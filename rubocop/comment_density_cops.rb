# frozen_string_literal: true

# House comment-density cops — is this method more explanation than code?
#
# Three cops, one question at three scales: the prose introducing a method
# (HeaderCommentDensity), the commentary inside its body (InternalCommentDensity),
# and the file as a whole (FileCommentDensity). They exist because the standard
# they enforce was written down twice and enforced only by eye, and by eye it
# kept regressing — a one-line change once acquired a nine-line comment.
#
# All three measure *height*: a comment line is a line given over entirely to
# comment, so a trailing note costs nothing. Each ratio divides by at least
# MinDenominator, which keeps a short method from being either nonsense to
# score or the cheapest place to park an essay.
#
# Wire it up per project, since a RuboCop plugin has to resolve inside CI's own
# checkout — copy this file in and point `require:` at the copy.
#
#   require:
#     - ./rubocop/comment_density_cops.rb
#
#   House/HeaderCommentDensity:
#     Max: 60
#     MinDenominator: 5
#     EndlessMinDenominator: 2

module RuboCop
  module Cop
    module House
      # Mechanics shared by the three cops.
      module CommentDensity
        MSG = "%<subject>s has %<comments>s of comment against %<code>s of code " \
              "(%<ratio>d%%); the maximum is %<max>d%%."

        YARD_TAG = /\A@\w+/

        private

        def density(comments, code, floor)
          (comments * 100.0 / [code, floor].max).round
        end

        def code_lines(node)
          Metrics::Utils::CodeLengthCalculator.new(
            node, processed_source, count_comments: false, foldable_types: []
          ).calculate
        end

        # A line that is nothing but comment. Reads the parsed comment list, so
        # a `#` inside a heredoc or a string is program text, as it should be.
        def comment_line_at(line)
          comment = processed_source.comment_at_line(line)
          return nil unless comment

          comment if comment.loc.expression.source_line.lstrip.start_with?("#")
        end

        # Directives and magic comments are machinery addressed to tools, not
        # explanation addressed to a reader, so they count as neither.
        def commentary?(comment) = !machinery?(comment)

        def machinery?(comment)
          RuboCop::DirectiveComment.new(comment).start_with_marker? ||
            RuboCop::MagicComment.parse(comment.text).any?
        end

        def commentary_at(line)
          comment = comment_line_at(line)
          comment if comment && commentary?(comment)
        end

        # YARD is API metadata rather than explanation, and its continuation
        # lines — an @example body included — are indented under their tag, so
        # whether a line is metadata depends on whether the one above it was.
        def metadata?(body, in_tag)
          YARD_TAG.match?(body) || (in_tag && (body.empty? || body.start_with?(" ")))
        end

        def comment_body(comment) = comment.text.sub(/\A#+\s?/, "")

        def offense_for(subject, comments, code, ratio)
          format(MSG, subject: subject, comments: lines(comments),
                      code: lines(code), ratio: ratio, max: max)
        end

        def lines(count) = "#{count} line#{'s' unless count == 1}"

        def signature(node) = node.loc.keyword.join(node.loc.name)

        def max = cop_config.fetch("Max")
      end

      # Flags a method body whose commentary outweighs the code it annotates.
      class InternalCommentDensity < Base
        include CommentDensity

        def on_def(node)
          comments = internal_comment_lines(node)
          return if comments.zero?

          code = code_lines(node)
          ratio = density(comments, code, cop_config.fetch("MinDenominator"))
          return if ratio <= max

          add_offense(signature(node),
                      message: offense_for("`#{node.method_name}`", comments, code, ratio))
        end
        alias on_defs on_def

        private

        def internal_comment_lines(node)
          ((node.first_line + 1)..node.last_line).count { |line| commentary_at(line) }
        end
      end

      # Flags a method header whose prose outweighs the method it introduces.
      class HeaderCommentDensity < Base
        include CommentDensity

        def on_def(node)
          comments = header_prose_lines(node)
          return if comments.zero?

          code = code_lines(node)
          ratio = density(comments, code, floor(node))
          return if ratio <= max

          add_offense(signature(node),
                      message: offense_for("`#{node.method_name}`", comments, code, ratio))
        end
        alias on_defs on_def

        private

        def header_prose_lines(node)
          in_tag = false
          header_bodies(node).count { |body| !(in_tag = metadata?(body, in_tag)) }
        end

        # Walks up from the `def`, stopping at the first line that is not a
        # comment. That is what makes a block sitting between two adjacent
        # one-liners belong to the def below it, the way a reader reads it.
        def header_bodies(node)
          line = node.first_line - 1
          bodies = []
          while (comment = comment_line_at(line))
            bodies.unshift(comment_body(comment)) if commentary?(comment)
            line -= 1
          end
          bodies
        end

        # Endless defs divide by a smaller floor: expressible on one line is not
        # the same as simple, and a method needing a paragraph of introduction
        # is usually asking for the ordinary form back.
        def floor(node)
          cop_config.fetch(node.endless? ? "EndlessMinDenominator" : "MinDenominator")
        end
      end

      # Flags a file given over more to commentary than to program.
      class FileCommentDensity < Base
        include CommentDensity
        include RangeHelp

        def on_new_investigation
          comments, code = tally
          return if comments.zero? || code.zero?

          ratio = density(comments, code, cop_config.fetch("MinDenominator"))
          return if ratio <= max

          add_offense(source_range(processed_source.buffer, 1, 0),
                      message: offense_for("This file", comments, code, ratio))
        end

        private

        # A line of program ends a tag block: carrying the state past it would
        # let one stray @tag near the top silence every indented comment below.
        def tally
          in_tag = false
          significant_lines.each_with_object([0, 0]) do |body, counts|
            if body == :code
              in_tag = false
              counts[1] += 1
            elsif !(in_tag = metadata?(body, in_tag))
              counts[0] += 1
            end
          end
        end

        # Each non-blank line as its comment body, or :code where the line is
        # program. Machinery drops out here, so it is invisible to the tag
        # block exactly as it is to the header walk.
        def significant_lines
          processed_source.lines.filter_map.with_index(1) do |text, line|
            next if text.strip.empty?

            comment = comment_line_at(line)
            next :code unless comment

            comment_body(comment) if commentary?(comment)
          end
        end
      end
    end
  end
end

# RuboCop can only describe a cop it holds defaults for: `--auto-gen-config`
# reads them (and crashes on nil), and `cop_config` falls back to them when a
# project omits a key. A cop loaded by `require:` gets no entry in default.yml,
# so it supplies its own. Thresholds here are the measured house numbers; a
# project overrides what it needs and inherits the rest.
RuboCop::ConfigLoader.default_configuration.tap do |defaults|
  shared = { "Enabled" => true, "VersionAdded" => "1.0", "Exclude" => [] }.freeze

  defaults["House/HeaderCommentDensity"] =
    shared.merge("Max" => 100, "MinDenominator" => 5, "EndlessMinDenominator" => 2)
  defaults["House/InternalCommentDensity"] = shared.merge("Max" => 15, "MinDenominator" => 7)
  defaults["House/FileCommentDensity"] = shared.merge("Max" => 40, "MinDenominator" => 10)
end
