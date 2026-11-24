# Frontend-only Crystal compiler entry point: parse + semantic + diagnostics.
#
# This binary never performs codegen and must be built with `-Dwithout_llvm`;
# no libLLVM symbol is referenced, so it can be linked natively without LLVM
# (verify with `otool -L`) and cross-compiled to wasm32-wasi.
#
# Build (native, macOS arm64 example):
#
#   CRYSTAL_CONFIG_TARGET=aarch64-apple-darwin \
#   CRYSTAL_CONFIG_PATH=$PWD/src \
#   CRYSTAL_CONFIG_LLVM_VERSION=21.1.8 \
#   LLVM_VERSION=21.1.8 LLVM_TARGETS=WebAssembly LLVM_LDFLAGS='' \
#   crystal build src/compiler/frontend_main.cr -o .build/crystal-frontend -Dwithout_llvm
#
# Usage:
#
#   crystal-frontend [--target TRIPLE] [--prelude NAME] [--error-format text|json]
#                    [--no-color] [--stats] main.cr

{% raise "frontend_main.cr must be built with -Dwithout_llvm" unless flag?(:without_llvm) %}

require "log"
require "json"
require "option_parser"
require "./crystal/annotatable"
require "./crystal/config"
require "./crystal/error"
require "./crystal/exception"
require "./crystal/util"
require "./crystal/warnings"
require "./crystal/gc_tuning" # GCTuning (called by ProgressTracker); no LLVM inside
require "./crystal/progress_tracker"
require "./crystal/crystal_path"
require "./crystal/syntax"
require "./crystal/types"
require "./crystal/program"
require "./crystal/codegen/link"                # LinkAnnotation (referenced by types.cr); no LLVM inside
require "./crystal/codegen/cache_dir"           # CacheDir (referenced by program.cr); no LLVM inside
require "./crystal/codegen/experimental"        # ExperimentalAnnotation (referenced by semantic_visitor); no LLVM inside
require "./crystal/codegen/types"               # has_inner_pointers? etc. (used by macro methods); only type-level LLVM refs
require "./crystal/codegen/ast"                 # no_returns?, Asm#dialect etc.; only enum-level LLVM refs
require "./crystal/formatter"                   # Crystal::Formatter (used by the `debug` macro method); pure syntax, no LLVM
require "./crystal/codegen/owner_shape_sharing" # OwnerShapeSharing (read by semantic/memory_census.cr); no LLVM inside
require "./crystal/codegen/stable_numbering"    # Program#stable_numbering (read by owner_shape_sharing.cr); no LLVM inside
require "./crystal/codegen/llvm_id"             # Program#llvm_id (read by owner_shape_sharing.cr); no LLVM inside
require "./crystal/infer_reuse/source_record"   # Program#infer_reuse_record type; plain data, no LLVM inside
require "./crystal/infer_reuse/file_edit"       # InferReuse::Refusal (raised by method_listing.cr); no LLVM inside
require "./crystal/infer_reuse/method_listing"  # MethodListReplay (read by source_record.cr and the macro interpreter); no LLVM inside
require "./crystal/macros"
# IMPORTANT: semantic MUST be required before macros/* (mirroring
# src/compiler/requires.cr). The macro interpreter's overload restrictions
# reference classes defined in semantic/ast.cr (TypeNode, MacroId, ...);
# requiring macros/* first silently mis-orders overloads (dispatch falls
# through to catch-alls at compile time AND runtime). See BREAK A-1 in the
# experiment notes.
require "./crystal/semantic"
require "./crystal/macros/*"
require "./crystal/frontend/type_layout"
require "./crystal/frontend/patches"
require "./crystal/frontend/target_profile"
require "./crystal/frontend/memory_limit"

Log.setup_from_env(default_level: :warn, default_sources: "crystal.*")

module Crystal
  module FrontendMain
    # C-4 fix (docs_c4_implementation_notes.md §Completeness): maximum AST
    # nesting depth accepted by the frontend. The parser's call-depth guard
    # (Parser::MAX_PARSE_RECURSION) bounds recursion that traps DURING parse,
    # but constructs that parse ITERATIVELY into a deep LEFT-NESTED AST
    # (`a && b && c…`, `a.b.c…`, `a[0][0]…`, `a rescue b rescue c…`,
    # `Int32****…`) complete parsing and would then trap later, in
    # normalize/semantic, while a recursive visitor walks the deep spine
    # (observed browser/wasmtime@1MB trap floor ≈ 500–1000 levels). This cap
    # sits far below that floor and is checked with an ITERATIVE walk (below)
    # right after parse, so such input degrades to a clean SyntaxException
    # instead of an uncatchable VM call-stack trap. Frontend-only: this file is
    # never compiled into the native compiler, so native builds are unaffected.
    MAX_AST_DEPTH = 128

    # One-level child collector: `visit` returns false so `accept` never
    # descends past the immediate children. This lets check_ast_depth below
    # enumerate a node's direct children WITHOUT the native recursion an
    # ordinary Visitor/`accept` walk would incur (which is exactly what would
    # trap on a deep AST).
    private class ChildCollector < Visitor
      getter children = [] of ASTNode

      def visit(node : ASTNode)
        @children << node
        false
      end
    end

    # Iterative (explicit-stack) max-depth check. Raises SyntaxException — the
    # same exception the parser raises for "syntax nesting too deep", caught by
    # `run`'s `rescue Crystal::CodeError` and emitted as an exit-1 diagnostic —
    # if any node is nested deeper than MAX_AST_DEPTH. Never recurses natively,
    # so it cannot itself trap on the very input it guards against. Bails at the
    # first over-deep node (does not walk the whole tree).
    def self.check_ast_depth(root : ASTNode, filename : String) : Nil
      stack = [{root, 1}]
      until stack.empty?
        node, depth = stack.pop
        if depth > MAX_AST_DEPTH
          loc = node.location
          raise SyntaxException.new(
            "syntax nesting too deep (exceeds #{MAX_AST_DEPTH})",
            loc.try(&.line_number) || 1,
            loc.try(&.column_number) || 1,
            loc.try(&.filename).try(&.to_s) || filename,
          )
        end
        collector = ChildCollector.new
        node.accept_children(collector)
        collector.children.each { |child| stack.push({child, depth + 1}) }
      end
    end

    def self.run(args = ARGV) : Nil
      target = nil
      prelude = "prelude"
      error_format = "text"
      color = true
      stats = false
      defines = [] of String
      filenames = [] of String
      profile_path = nil
      memory_limit = nil
      record_profile_path = nil

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: crystal-frontend [options] file.cr\n\nOptions:"
        opts.on("--target TRIPLE", "Target triple to analyze for (default: #{Config.host_target})") { |t| target = t }
        opts.on("--target-profile FILE", "Target profile JSON: target, flags and recorded macro shell output") { |path| profile_path = path }
        opts.on("--record-target-profile FILE", "Write a target profile with the macro shell output this check needed (native builds only)") { |path| record_profile_path = path }
        opts.on("--prelude NAME", "Prelude to use (default: prelude)") { |p| prelude = p }
        opts.on("--error-format FORMAT", "Error output format: text|json (default: text)") { |f| error_format = f }
        opts.on("-D FLAG", "--define FLAG", "Define a compile-time flag for the analyzed program") { |f| defines << f }
        opts.on("--no-color", "Disable colored output") { color = false }
        opts.on("--memory-limit BYTES", "Most GC heap the check may use; past it, exit 3 with a message") { |bytes| memory_limit = bytes.to_u64 }
        opts.on("--stats", "Print elapsed time of each phase") { stats = true }
        opts.on("--version", "Show version") do
          puts Config.description
          exit
        end
        opts.on("-h", "--help", "Show this message") do
          puts opts
          exit
        end
        opts.unknown_args do |before_dash, _|
          filenames = before_dash
        end
      end
      parser.parse(args)

      if filenames.size != 1
        STDERR.puts parser
        exit 1
      end

      filename = File.expand_path(filenames.first)
      unless File.file?(filename)
        STDERR.puts "Error: file '#{filenames.first}' does not exist"
        exit 1
      end
      source_code = File.read(filename)

      memory_limit.try { |bytes| FrontendMemoryLimit.apply(bytes) }

      profile = profile_path.try { |path| FrontendTargetProfile.load(path) }
      target ||= profile.try(&.target)

      begin
        analyze(filename, source_code, target, prelude, error_format, color, stats, defines, profile, record_profile_path)
      rescue ex : Crystal::CodeError
        ex.color = color
        if error_format == "json"
          STDERR.puts ex.to_json
        else
          STDERR.puts ex
        end
        exit 1
      rescue ex : Crystal::Error
        while cause = ex.cause
          STDERR.puts "Error: #{ex.message}"
          break unless cause.is_a?(::Exception)
          ex = cause
        end
        STDERR.puts "Error: #{ex.message}"
        exit 1
      end
    end

    def self.analyze(filename, source_code, target, prelude, error_format, color, stats, defines = [] of String, profile : FrontendTargetProfile? = nil, record_profile_path : String? = nil) : Nil
      progress_tracker = ProgressTracker.new
      progress_tracker.stats = stats

      program = Program.new
      program.filename = filename
      target_triple = target # local copy: closured vars don't flow-narrow
      program.codegen_target = Codegen::Target.new(target_triple || Config.host_target.to_s)
      program.color = color
      program.progress_tracker = progress_tracker
      program.user_flags.concat(defines)
      program.flags.concat(defines)
      profile.try &.apply(program)
      # Crystal::VERSION and its peers (Crystal 1.22 defines them once the
      # target and the flags are known, not when the program is made).
      program.define_crystal_constants
      program.recorded_macro_shell_output_by_command = {} of String => String if record_profile_path

      node = progress_tracker.stage("Parse") do
        program.requires.add filename
        parser2 = program.new_parser(source_code)
        parser2.filename = filename
        parsed = parser2.parse.as(ASTNode)

        # C-4: reject deep LEFT-NESTED ASTs (iterative-parse chains) before any
        # recursive frontend visitor (normalize/semantic) walks them and traps
        # the ~1 MB browser VM call stack. See MAX_AST_DEPTH above.
        check_ast_depth(parsed, filename)

        location = Location.new(program.filename, 1, 1)
        nodes = Expressions.new([Require.new(prelude).at(location), parsed] of ASTNode)
        program.normalize(nodes)
      end

      node = program.semantic(node)

      program.warnings.report(STDERR)

      if record_profile_path
        recorded = FrontendTargetProfile.new(program.codegen_target.to_s, defines, program.recorded_macro_shell_output_by_command || {} of String => String)
        File.write(record_profile_path, recorded.to_pretty_json)
      end

      if error_format == "json"
        JSON.build(STDOUT) do |json|
          json.object do
            json.field "status", "ok"
            json.field "file", filename
            json.field "target", program.codegen_target.to_s
            json.field "warnings", program.warnings.infos.size
          end
        end
        STDOUT.puts
      else
        puts "frontend: OK (#{filename}, target: #{program.codegen_target})"
      end
    end
  end
end

Crystal::FrontendMain.run
