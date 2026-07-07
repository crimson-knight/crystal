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
require "./crystal/progress_tracker"
require "./crystal/crystal_path"
require "./crystal/syntax"
require "./crystal/types"
require "./crystal/program"
require "./crystal/codegen/link"         # LinkAnnotation (referenced by types.cr); no LLVM inside
require "./crystal/codegen/cache_dir"    # CacheDir (referenced by program.cr); no LLVM inside
require "./crystal/codegen/experimental" # ExperimentalAnnotation (referenced by semantic_visitor); no LLVM inside
require "./crystal/codegen/types"        # has_inner_pointers? etc. (used by macro methods); only type-level LLVM refs
require "./crystal/codegen/ast"          # no_returns?, Asm#dialect etc.; only enum-level LLVM refs
require "./crystal/formatter" # Crystal::Formatter (used by the `debug` macro method); pure syntax, no LLVM
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

Log.setup_from_env(default_level: :warn, default_sources: "crystal.*")

module Crystal
  module FrontendMain
    def self.run(args = ARGV) : Nil
      target = nil
      prelude = "prelude"
      error_format = "text"
      color = true
      stats = false
      defines = [] of String
      filenames = [] of String

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: crystal-frontend [options] file.cr\n\nOptions:"
        opts.on("--target TRIPLE", "Target triple to analyze for (default: #{Config.host_target})") { |t| target = t }
        opts.on("--prelude NAME", "Prelude to use (default: prelude)") { |p| prelude = p }
        opts.on("--error-format FORMAT", "Error output format: text|json (default: text)") { |f| error_format = f }
        opts.on("-D FLAG", "--define FLAG", "Define a compile-time flag for the analyzed program") { |f| defines << f }
        opts.on("--no-color", "Disable colored output") { color = false }
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

      begin
        analyze(filename, source_code, target, prelude, error_format, color, stats, defines)
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

    def self.analyze(filename, source_code, target, prelude, error_format, color, stats, defines = [] of String) : Nil
      progress_tracker = ProgressTracker.new
      progress_tracker.stats = stats

      program = Program.new
      program.filename = filename
      target_triple = target # local copy: closured vars don't flow-narrow
      program.codegen_target = Codegen::Target.new(target_triple || Config.host_target.to_s)
      program.color = color
      program.progress_tracker = progress_tracker
      program.flags.concat(defines)

      node = progress_tracker.stage("Parse") do
        program.requires.add filename
        parser2 = program.new_parser(source_code)
        parser2.filename = filename
        parsed = parser2.parse.as(ASTNode)

        location = Location.new(program.filename, 1, 1)
        nodes = Expressions.new([Require.new(prelude).at(location), parsed] of ASTNode)
        program.normalize(nodes)
      end

      node = program.semantic(node)

      program.warnings.report(STDERR)

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
