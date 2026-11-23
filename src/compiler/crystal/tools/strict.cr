require "option_parser"
require "../syntax/ast"
require "../compiler"
require "./formatter"
require "./strict/*"

# `crystal tool strict`: converts files to strict form (see
# `semantic/strict_files.cr`) from what type inference found for a program.
#
# For each file it adds the first line `# crystal: strict`, writes into each
# method the argument, block and return types its typed copies agree on, and
# marks with `@[Override]` each method that overrides or redefines another.
# A method whose types differ by caller is left as it is and listed with the
# reason; `--unions` writes the union (or the common base type) instead.
#
# Unless `--no-verify` is given, the converted files are checked by type
# inference of the program: a method whose new types break the build is
# put back as it was (and listed), and the conversion runs again on the
# result until it changes nothing, so a second run of the tool finds nothing
# to do.
module Crystal
  class Command
    private def strict
      status = StrictTool::Command.new(options).run
      exit status unless status == 0
    end
  end

  module StrictTool
    STRICT_MARKER = Program::STRICT_MARKER

    # One text insertion at a 1-based line and character column (the text is
    # inserted before the character at that column).
    record Insertion, line : Int32, column : Int32, text : String

    # What the tool decided for one method.
    class MethodPlan
      getter a_def : Def
      getter owner : ModuleType
      getter description : String

      # Restriction text for each parameter index that gets one.
      getter arg_texts = {} of Int32 => String
      property block_text : String?
      property return_text : String?
      property? needs_override = false

      # The earlier def with the same signature this one replaced.
      property replaced : Def?

      # Why the method's types are left as they are; `nil` when it is typed.
      property reason : String?

      # The types of a parameter whose callers disagree, kept for the report.
      getter unions = [] of String

      # Set when the verification build rejected the method's new types.
      property rejection : String?

      # The method's place among the defs of its file.
      property ordinal = -1

      # Drops the types this plan would write, for *reason*.
      def clear_types(reason : String) : Nil
        @arg_texts.clear
        @block_text = nil
        @return_text = nil
        @reason = reason
      end

      def initialize(@a_def : Def, @owner : ModuleType, @description : String)
      end

      def writes_types? : Bool
        !arg_texts.empty? || !block_text.nil? || !return_text.nil?
      end

      def changes? : Bool
        writes_types? || needs_override?
      end

      def location : Location
        @a_def.location.not_nil!
      end
    end

    # What happened to one method over all rounds.
    class Outcome
      getter description : String
      property? typed = false
      property? override = false
      property reason : String?

      def initialize(@description : String)
      end
    end

    # A unit the verification build can turn off on its own: the strict
    # marker of a file, or the edits of one method.
    class Unit
      getter file : FileState
      getter plan : MethodPlan?
      property? active = true

      def initialize(@file : FileState, @plan : MethodPlan? = nil)
      end

      def marker? : Bool
        @plan.nil?
      end
    end

    # A file being converted: its text on disk at the start, its text now,
    # and what the tool decided for its methods.
    class FileState
      getter filename : String
      getter original_text : String
      property text : String
      getter plans = [] of MethodPlan
      getter left_ordinary_reason : String?
      property? in_program = false

      def initialize(@filename : String)
        @original_text = File.read(@filename)
        @text = @original_text
      end

      def strict? : Bool
        first_line = @text.each_line.first?
        !first_line.nil? && first_line.rstrip == STRICT_MARKER
      end

      def leave_ordinary(reason : String) : Nil
        @left_ordinary_reason ||= reason
      end
    end

    # The source of one file as lines, with the positions the edits need.
    class SourceText
      getter lines : Array(String)

      def initialize(text : String)
        @lines = text.split('\n', remove_empty: false)
      end

      def char_at(line : Int32, column : Int32) : Char?
        @lines[line - 1]?.try &.[column - 1]?
      end

      # Applies *insertions* and returns the new text.
      def apply(insertions : Array(Insertion)) : String
        lines = @lines.dup
        insertions.sort_by { |insertion| {-insertion.line, -insertion.column} }.each do |insertion|
          line_text = lines[insertion.line - 1]
          byte_index = line_text.char_index_to_byte_index(insertion.column - 1) || line_text.bytesize
          lines[insertion.line - 1] = String.build do |io|
            io.write line_text.to_slice[0, byte_index]
            io << insertion.text
            io.write line_text.to_slice[byte_index, line_text.bytesize - byte_index]
          end
        end
        lines.join('\n')
      end

      # The position after the word that starts at *line*:*column* (an
      # identifier, optionally starting with `@` or `@@`).
      def word_end(line : Int32, column : Int32) : {Int32, Int32}
        while char_at(line, column) == '@'
          column += 1
        end
        while (char = char_at(line, column)) && (char.alphanumeric? || char == '_' || char.ord > 0x7f)
          column += 1
        end
        {line, column}
      end

      # The position of the next character that is not a space or a tab,
      # crossing line ends when *newlines* is true.
      def skip_space(line : Int32, column : Int32, newlines = false) : {Int32, Int32}
        loop do
          char = char_at(line, column)
          if char == ' ' || char == '\t'
            column += 1
          elsif char.nil? && newlines && line < @lines.size
            line += 1
            column = 1
          else
            return {line, column}
          end
        end
      end

      # The position after the `)` that closes the `(` at *line*:*column*,
      # skipping nested brackets, strings and characters.
      def after_closing_paren(line : Int32, column : Int32) : {Int32, Int32}?
        depth = 0
        in_string = false
        loop do
          char = char_at(line, column)
          if char.nil?
            return nil if line >= @lines.size
            line += 1
            column = 1
            next
          end
          if in_string
            if char == '\\'
              column += 1
            elsif char == '"'
              in_string = false
            end
          else
            case char
            when '"'
              in_string = true
            when '\''
              # A character literal: skip to its closing quote.
              column += 1
              column += 1 if char_at(line, column) == '\\'
              while (next_char = char_at(line, column + 1)) && next_char != '\''
                column += 1
              end
              column += 1
            when '#'
              column = (@lines[line - 1]?.try(&.size) || 0) + 1
              next
            when '(', '[', '{'
              depth += 1
            when ')', ']', '}'
              depth -= 1
              return {line, column + 1} if depth == 0
            end
          end
          column += 1
        end
      end
    end

    # Collects the defs written in a file, in source order.
    class DefCollector < Visitor
      getter defs = [] of Def

      def visit(node : Def)
        @defs << node
        false
      end

      def visit(node : ASTNode)
        true
      end
    end

    class Command
      @targets = [] of String
      @entries = [] of String
      @flags = [] of String
      @prelude : String?
      @check = false
      @dry_run = false
      @unions = false
      @verify = true
      @max_rounds = 4
      @max_builds = 120

      @files = [] of FileState
      @file_by_name = {} of String => FileState
      @builds = 0
      @strict_warnings_before : Int32?
      @strict_warnings_after : Int32?

      def initialize(@options : Array(String), @output : IO = STDOUT, @error_output : IO = STDERR)
      end

      # Raised to end the run with *status* after its message is printed.
      class Stop < Exception
        getter status : Int32

        def initialize(@status : Int32)
          super("stopped with status #{status}")
        end
      end

      # Converts the files and returns the exit status: 1 when the program does
      # not build, or with `--check` when a file would change; 0 otherwise.
      def run : Int32
        run_conversion
        0
      rescue stop : Stop
        stop.status
      end

      private def run_conversion : Nil
        parse_options
        @files = expand_targets.map { |filename| FileState.new(filename) }
        abort_with "no .cr files to convert" if @files.empty?
        @files.each { |file| @file_by_name[file.filename] = file }
        @entries = @files.map(&.filename) if @entries.empty?

        writes_to_disk = !@check && !@dry_run
        begin
          convert
          @files.each { |file| file.text = formatted(file) }
          print_report
          print_diffs if @dry_run
        ensure
          unless writes_to_disk
            @files.each { |file| File.write(file.filename, file.original_text) if File.read(file.filename) != file.original_text }
          end
        end
        if writes_to_disk
          @files.each { |file| File.write(file.filename, file.text) if file.text != file.original_text }
        end
        raise Stop.new(1) if @check && @files.any? { |file| file.text != file.original_text }
      end

      private def parse_options : Nil
        parser = OptionParser.new do |opts|
          opts.banner = <<-USAGE
            Usage: crystal tool strict [options] <files or directories>

            Converts each file to a strict file: adds the first line `#{STRICT_MARKER}`,
            writes the types every caller agrees on into each method, and marks methods
            that override or redefine another with @[Override]. Methods whose types
            differ by caller are listed and left as they are.

            Options:
            USAGE
          opts.on("--entry FILE", "Program entry file whose types are used (repeatable; default: the files given)") do |entry|
            @entries << File.expand_path(entry)
          end
          opts.on("--check", "Report what would change, write nothing; exit 1 if anything would change") do
            @check = true
          end
          opts.on("--dry-run", "Print a diff of what would change, write nothing") do
            @dry_run = true
          end
          opts.on("--unions", "Write the union (or common base type) when callers pass different types") do
            @unions = true
          end
          opts.on("--no-verify", "Skip the verification build of the converted files") do
            @verify = false
          end
          opts.on("-D FLAG", "--define FLAG", "Define a compile-time flag") do |flag|
            @flags << flag
          end
          opts.on("--prelude FILE", "Use given file as prelude") do |prelude|
            @prelude = prelude
          end
          opts.on("--no-color", "Disable colored output") do
          end
          opts.on("-h", "--help", "Show this message") do
            @output.puts opts
            raise Stop.new(0)
          end
          opts.unknown_args do |args, after_dash|
            @targets.concat args
            @targets.concat after_dash
          end
          opts.invalid_option do |option|
            abort_with "unknown option: #{option}"
          end
        end
        parser.parse(@options)
        abort_with "give the files or directories to convert (crystal tool strict --help)" if @targets.empty?
      end

      private def expand_targets : Array(String)
        filenames = [] of String
        @targets.each do |target|
          if File.directory?(target)
            Dir.glob(::Path[target].to_posix.join("**", "*.cr").to_s).sort!.each { |name| filenames << File.expand_path(name) }
          elsif File.file?(target)
            filenames << File.expand_path(target)
          else
            abort_with "no such file or directory: #{target}"
          end
        end
        filenames.uniq
      end

      private def abort_with(message : String) : NoReturn
        @error_output.puts "Error: #{message}"
        raise Stop.new(1)
      end

      # One type inference of the program with the files as they are on
      # disk. Returns the recorder, or the error the build stopped at.
      private def infer : StrictToolRecorder | CodeError
        @builds += 1
        compiler = Compiler.new
        compiler.no_codegen = true
        compiler.color = false
        compiler.flags.concat @flags
        if prelude = @prelude
          compiler.prelude = prelude
        end
        recorder = StrictToolRecorder.new(@file_by_name.keys.to_set)
        sources = @entries.map { |entry| Compiler::Source.new(entry, File.read(entry)) }
        compiler.compile_configure_program(sources, "strict-tool") do |program|
          program.strict_tool_recorder = recorder
        end
        @last_warnings = compiler.warnings.infos.count(&.includes?("strict file:"))
        recorder
      rescue ex : CodeError
        ex
      end

      @last_warnings = 0

      # What happened to each method over all rounds, by file and the method's
      # order among the file's defs.
      @outcomes = {} of {String, Int32} => Outcome

      # Methods whose types the verification build rejected (same key); they
      # stay as they are in later rounds.
      @rejections = {} of {String, Int32} => String

      # Files the verification build could not make strict.
      @ordinary_files = Set(String).new

      private def convert : Nil
        first = infer
        if first.is_a?(CodeError)
          @error_output.puts "Error: the program does not build as it is, so there are no types to read:"
          error_frames(first).each { |frame| @error_output.puts "  #{relative(frame[1])}:#{frame[2]}:#{frame[3]}: #{first_line(frame[0])}" }
          @error_output.puts error_message(first)
          raise Stop.new(1)
        end
        @strict_warnings_before = @last_warnings
        recorder = first

        @max_rounds.times do
          plan_round(recorder)
          units = new_units
          if units.empty?
            record_outcomes(units)
            break
          end
          write_units(units)
          if @verify
            recorder = verify(units)
            record_outcomes(units)
            break unless recorder
          else
            units.map(&.file).uniq.each { |file| file.text = File.read(file.filename) }
            record_outcomes(units)
            break
          end
        end
        @strict_warnings_after = @last_warnings if @verify
      end

      # Plans every declared def of the converted files from *recorder*.
      private def plan_round(recorder : StrictToolRecorder) : Nil
        planner = Planner.new(recorder, unions: @unions)
        @files.each(&.plans.clear)
        recorder.declarations.each do |declaration|
          location = declaration.a_def.location || next
          filename = location.filename
          next unless filename.is_a?(String)
          file = @file_by_name[filename]? || next
          file.in_program = true
          ast_defs = file_ast_defs(file)
          ast_def = ast_defs[location_key(location)]? || next
          plan = planner.plan(declaration)
          plan.ordinal = ast_defs.keys.index!(location_key(location))
          if rejection = @rejections[{filename, plan.ordinal}]?
            plan.clear_types(rejection)
          end
          if plan.writes_types? && Editor.new(SourceText.new(file.text), ast_def, plan).insertions.nil?
            plan.clear_types("its signature has a form the tool can't edit, so its types are left for you to write")
          end
          file.plans << plan
        end
        planner.mark_overrides(@files.flat_map(&.plans))
      end

      # The defs of *file*'s current text, parsed once per text.
      private def file_ast_defs(file : FileState) : Hash({Int32, Int32}, Def)
        cached = @ast_defs_cache[file.filename]?
        return cached[1] if cached && cached[0] == file.text
        defs = file_defs(file.text, file.filename)
        @ast_defs_cache[file.filename] = {file.text, defs}
        defs
      end

      @ast_defs_cache = {} of String => {String, Hash({Int32, Int32}, Def)}

      private def record_outcomes(units : Array(Unit)) : Nil
        @files.each do |file|
          file.plans.each do |plan|
            key = {file.filename, plan.ordinal}
            outcome = @outcomes[key] ||= Outcome.new(plan.description)
            unit = units.find { |candidate| candidate.plan.same?(plan) }
            applied = unit && unit.active? && !@ordinary_files.includes?(file.filename)
            if applied && plan.writes_types?
              outcome.typed = true
              outcome.reason = nil
            end
            outcome.override = true if applied && plan.needs_override?
            unless outcome.typed?
              if rejection = plan.rejection
                outcome.reason = "the build fails when it is typed once: #{rejection}"
              elsif reason = plan.reason
                outcome.reason = reason
              end
            end
          end
        end
      end

      private def new_units : Array(Unit)
        units = [] of Unit
        @files.each do |file|
          next unless file.in_program?
          next if @ordinary_files.includes?(file.filename)
          units << Unit.new(file) unless file.strict?
          file.plans.each do |plan|
            units << Unit.new(file, plan) if plan.changes?
          end
        end
        units
      end

      # Writes each file with the active units of *units* applied to its
      # current text.
      private def write_units(units : Array(Unit)) : Nil
        units.group_by(&.file).each do |file, file_units|
          File.write(file.filename, edited_text(file, file_units))
        end
      end

      private def edited_text(file : FileState, units : Array(Unit)) : String
        active = units.select(&.active?)
        source = SourceText.new(file.text)
        ast_defs = file_defs(file.text, file.filename)
        insertions = [] of Insertion
        active.each do |unit|
          if plan = unit.plan
            ast_def = ast_defs[location_key(plan.location)]? || next
            Editor.new(source, ast_def, plan).insertions.try &.each { |insertion| insertions << insertion }
          else
            insertions << Insertion.new(1, 1, "#{STRICT_MARKER}\n")
          end
        end
        source.apply(insertions)
      end

      private def location_key(location : Location) : {Int32, Int32}
        {location.line_number, location.column_number}
      end

      # The defs written in *text*, by the position of their `def`.
      private def file_defs(text : String, filename : String) : Hash({Int32, Int32}, Def)
        parser = Parser.new(text)
        parser.filename = filename
        collector = DefCollector.new
        parser.parse.accept collector
        collector.defs.each_with_object({} of {Int32, Int32} => Def) do |a_def, defs|
          if location = a_def.location
            defs[location_key(location)] = a_def
          end
        end
      end

      # Builds the program with *units* written; turns off each unit the
      # build blames until it builds. Returns the recorder of the last
      # (passing) build, or `nil` when the build budget ran out.
      private def verify(units : Array(Unit)) : StrictToolRecorder?
        loop do
          result = infer
          return commit(units, result) if result.is_a?(StrictToolRecorder)

          if @builds >= @max_builds
            @error_output.puts "strict tool: stopped after #{@builds} builds; putting back the last round's changes"
            units.each { |unit| reject(unit, "not verified: the build budget ran out") }
            write_units(units)
            return nil
          end

          next write_units(units) if add_missing_override(units, result)
          blamed = blame(units, result)
          blamed = bisect(units) if blamed.empty?
          return nil if blamed.empty?
          blamed.each { |unit| reject(unit, error_message(result)) }
          # A file left ordinary keeps its text: none of its edits stay.
          units.each { |unit| unit.active = false if @ordinary_files.includes?(unit.file.filename) }
          write_units(units)
        end
      end

      private def commit(units : Array(Unit), recorder : StrictToolRecorder) : StrictToolRecorder
        units.map(&.file).uniq.each { |file| file.text = File.read(file.filename) }
        recorder
      end

      private def reject(unit : Unit, message : String) : Nil
        unit.active = false
        file = unit.file
        if plan = unit.plan
          plan.rejection = message
          @rejections[{file.filename, plan.ordinal}] = "the build fails when it is typed once: #{message}"
        else
          @ordinary_files << file.filename
          file.leave_ordinary("the build fails when the file is strict: #{message}")
        end
      end

      # A strict file asks for @[Override] on a method the planner did not
      # mark: mark it and build again.
      private def add_missing_override(units : Array(Unit), error : CodeError) : Bool
        error_frames(error).reverse_each do |frame|
          message, filename, line, column = frame
          next unless message.includes?("Mark this definition @[Override]")
          unit = unit_at(units, filename, line, column, edited_only: false)
          if unit && (plan = unit.plan) && !plan.needs_override?
            plan.needs_override = true
            return true
          end
        end
        false
      end

      # The units whose code holds a frame of the error: the edited method
      # nearest the error, or the marker of a file whose already typed method
      # fails once it is typed once.
      private def blame(units : Array(Unit), error : CodeError) : Array(Unit)
        frames = error_frames(error)
        frames.reverse_each do |frame|
          _, filename, line, column = frame
          unit = unit_at(units, filename, line, column, edited_only: true)
          return [unit] if unit
        end
        frames.reverse_each do |frame|
          _, filename, line, column = frame
          file = @file_by_name[filename]? || next
          marker = units.find { |unit| unit.active? && unit.marker? && unit.file.same?(file) }
          return [marker] if marker
        end
        [] of Unit
      end

      # The active unit of the method whose body holds *line*:*column* in the
      # text of *filename* now on disk.
      private def unit_at(units : Array(Unit), filename : String, line : Int32, column : Int32, edited_only : Bool) : Unit?
        file = @file_by_name[filename]? || return nil
        text = File.read(filename)
        # Map the def at this position (in the edited text) back to its plan
        # through its order among the file's defs.
        edited_defs = file_defs(text, filename).values
        index = edited_defs.index do |a_def|
          start = a_def.location.not_nil!
          finish = a_def.end_location || start
          (start.line_number - 1 <= line <= finish.line_number) && !(line == finish.line_number && column > finish.column_number)
        end
        return nil unless index
        original_defs = file_defs(file.text, filename).values
        original_def = original_defs[index]? || return nil
        key = location_key(original_def.location.not_nil!)
        units.find do |unit|
          next false unless unit.active? && unit.file.same?(file)
          plan = unit.plan || next false
          next false if edited_only && !plan.writes_types?
          location_key(plan.location) == key
        end
      end

      # Each frame of *error* from the outermost call to the error itself.
      private def error_frames(error : CodeError) : Array({String, String, Int32, Int32})
        frames = [] of {String, String, Int32, Int32}
        current = error
        while current
          case current
          when TypeException
            filename = current.@filename
            line = current.line_number
            if filename.is_a?(String) && line
              frames << {current.message.to_s, File.expand_path(filename), line, current.column_number}
            elsif filename.is_a?(VirtualFile) && (expanded = filename.expanded_location) && (expanded_filename = expanded.filename).is_a?(String)
              frames << {current.message.to_s, File.expand_path(expanded_filename), expanded.line_number, expanded.column_number}
            end
            current = current.inner
          when SyntaxException
            filename = current.filename
            if filename.is_a?(String)
              frames << {current.message.to_s, File.expand_path(filename), current.line_number, current.column_number}
            end
            current = nil
          else
            current = nil
          end
        end
        frames
      end

      # The message of the innermost frame of *error* that has one.
      private def error_message(error : CodeError) : String
        message = ""
        current = error
        while current
          text = first_line(current.message)
          message = text unless text.empty?
          current = current.is_a?(TypeException) ? current.inner : nil
        end
        message
      end

      private def first_line(message : String?) : String
        (message || "").each_line.first?.try(&.strip) || ""
      end

      # Finds the first active unit whose edits break the build, by building
      # with the first k active units for a growing k (binary search; the
      # build with none passed in the round before).
      private def bisect(units : Array(Unit)) : Array(Unit)
        active = units.select(&.active?)
        return [] of Unit if active.empty?
        low = 0
        high = active.size
        while high - low > 1
          middle = (low + high) // 2
          active.each_with_index { |unit, index| unit.active = index < middle }
          write_units(units)
          passed = infer.is_a?(StrictToolRecorder)
          if passed
            low = middle
          else
            high = middle
          end
        end
        active.each { |unit| unit.active = true }
        [active[high - 1]]
      end

      private def formatted(file : FileState) : String
        text = File.read(file.filename)
        return text if text == file.original_text
        Crystal.format(text, file.filename)
      rescue ex
        @error_output.puts "strict tool: the formatter could not format #{file.filename} (#{ex.message}); the file is written unformatted"
        File.read(file.filename)
      end

      private def relative(filename : String) : String
        ::Path[filename].relative_to(Dir.current).to_s
      end

      private def print_report : Nil
        typed = 0
        overrides = 0
        left = 0
        @files.each do |file|
          changed = file.text != file.original_text
          state = changed ? (@check || @dry_run ? "would change" : "converted") : "unchanged"
          @output.puts "#{relative(file.filename)}: #{state}"
          unless file.in_program?
            @output.puts "  not part of the program built from the entry files; nothing to read types from"
            next
          end
          if reason = file.left_ordinary_reason
            @output.puts "  left an ordinary file: #{reason}"
          end
          @outcomes.each do |key, outcome|
            next unless key[0] == file.filename
            if outcome.typed?
              typed += 1
              @output.puts "  typed     #{outcome.description}#{outcome.override? ? ", marked @[Override]" : ""}"
            elsif outcome.override?
              @output.puts "  marked    #{outcome.description} @[Override]"
            end
            overrides += 1 if outcome.override?
            if reason = outcome.reason
              left += 1
              @output.puts "  left      #{outcome.description}: #{reason}"
            end
          end
        end
        @output.puts
        @output.puts "#{typed} methods typed, #{overrides} marked @[Override], #{left} left as they are (#{@builds} type inference builds)"
        if (before = @strict_warnings_before) && (after = @strict_warnings_after)
          @output.puts "strict-file warnings in the program: #{before} before, #{after} after"
        end
      end

      private def print_diffs : Nil
        @files.each do |file|
          next if file.text == file.original_text
          name = relative(file.filename)
          @output.puts "--- a/#{name}"
          @output.puts "+++ b/#{name}"
          LineDiff.new(file.original_text.split('\n'), file.text.split('\n')).hunks(@output)
        end
      end
    end
  end
end
