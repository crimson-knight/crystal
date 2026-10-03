require "json"
require "./syntax/ast"
require "./syntax/visitor"

module Crystal
  # Structural signature of a type declaration (class, struct, module, enum, lib).
  # Captures the type's name, kind, parent type, and generic parameters.
  # Used for incremental compilation: if a type's signature hasn't changed,
  # dependent files may not need re-processing.
  record TypeDeclarationSig,
    name : String,
    kind : String,
    parent : String?,
    generic_params : Array(String) do
    include JSON::Serializable
  end

  # Structural signature of a method definition.
  # Captures the method name, argument names and type restrictions, return type
  # restriction, and whether it's abstract. Method body changes do NOT affect
  # this signature -- only the interface (arguments, types, abstract flag).
  record MethodSig,
    name : String,
    arg_names : Array(String),
    arg_restrictions : Array(String?),
    return_restriction : String?,
    is_abstract : Bool do
    include JSON::Serializable
  end

  # Aggregate top-level signature for a single source file.
  # Captures everything that TopLevelVisitor registers for this file:
  # type declarations, method signatures, include/extend (mixins),
  # constants, and whether the file contains top-level macro calls.
  #
  # If the FileTopLevelSignature for a changed file is identical to
  # the cached version, the change is "body-only" (method bodies changed
  # but no structural/interface change). Dependent files do not need
  # re-processing in that case.
  record FileTopLevelSignature,
    type_declarations : Array(TypeDeclarationSig),
    method_signatures : Array(MethodSig),
    mixins : Array(String),
    constants : Array(String),
    has_top_level_macro_calls : Bool do
    include JSON::Serializable
  end

  # Pre-allocation sizing hints captured after a compilation.
  # Stored in the incremental cache so that subsequent compilations can
  # pre-size hash tables and string pools, reducing rehash overhead.
  record AllocationHints,
    string_pool_capacity : Int32 = 0,
    unions_capacity : Int32 = 0,
    total_types_count : Int32 = 0,
    total_defs_count : Int32 = 0,
    module_count : Int32 = 0 do
    include JSON::Serializable
  end

  # Fingerprint of a single source file for incremental compilation tracking.
  # Includes mtime, content hash, and byte size for fast change detection.
  record FileFingerprint,
    filename : String,
    mtime_epoch : Int64,
    content_hash : String,
    byte_size : Int64 do
    include JSON::Serializable
  end

  # Identity of an output binary produced by an incremental build: its path,
  # mtime and size right after it was written. A compilation (or link) may
  # only be skipped when the output on disk still matches this stamp, i.e. it
  # is the very file this cache produced and nothing has replaced it since.
  record OutputStamp,
    path : String,
    mtime_epoch : Int64,
    byte_size : Int64 do
    include JSON::Serializable

    def self.for?(path : String) : OutputStamp?
      info = File.info?(path)
      return unless info
      new(path, info.modification_time.to_unix_ms, info.size)
    end

    def matches_file? : Bool
      OutputStamp.for?(path) == self
    end
  end

  # Serializable cache data written to disk between compilations.
  # Tracks compiler version, target, flags, and per-file fingerprints
  # so the cache can be invalidated when any of these change.
  # Also stores the module-to-file mapping from codegen so that unchanged
  # modules can skip LLVM IR generation entirely on the next build.
  class IncrementalCacheData
    include JSON::Serializable

    getter compiler_version : String
    getter codegen_target : String
    getter flags : Array(String)
    getter prelude : String

    # Codegen/link settings that are not part of `flags` but change the
    # output (optimization level, debug info, static, link flags, ...).
    # A mismatch invalidates the cache, like a flags mismatch.
    getter build_settings : String = ""

    # The output produced by the compilation that wrote this cache.
    # Nil when no output was produced (e.g. old cache format).
    @[JSON::Field(emit_null: false)]
    getter output : OutputStamp? = nil

    # External state read by macros (env vars, command outputs, files) with
    # the value observed, see `IncrementalCache::ExternalInput`.
    getter external_macro_inputs : Hash(String, String?) = {} of String => String?

    # Whether a macro read external state that can't be re-checked (a `run`
    # with `CRYSTAL_MACRO_RUN_TRUST=0`). If so, the next build can't be
    # skipped as a whole.
    getter? unverifiable_macro_inputs : Bool = false

    getter file_fingerprints : Hash(String, FileFingerprint)

    # Maps LLVM module name => array of source filenames that contributed
    # methods/defs to that module. Used by Phase 4 codegen caching to
    # determine if a module can be skipped (all contributing files unchanged).
    # Nil when not available (e.g. single-module mode, or old cache format).
    @[JSON::Field(emit_null: false)]
    getter module_file_mapping : Hash(String, Array(String))? = nil

    # Per-file top-level signatures extracted after the TopLevelVisitor pass.
    # Used by Phase 6 signature tracking to determine whether a changed file
    # has only body-level changes (signature identical) or structural changes
    # (signature differs). Nil when not available (old cache format or
    # incremental signatures not yet computed).
    @[JSON::Field(emit_null: false)]
    getter file_signatures : Hash(String, FileTopLevelSignature)? = nil

    # Pre-allocation sizing hints from the previous compilation.
    # Used to pre-size data structures (string pools, hash tables) on the
    # next build, reducing rehash overhead. Nil when not available (old
    # cache format or first compilation).
    @[JSON::Field(emit_null: false)]
    getter allocation_hints : AllocationHints? = nil

    # File-level dependency graph from the previous compilation.
    # Maps user_file => Array(provider_files): which files each file depends on
    # for method calls and type definitions. Used for smarter invalidation:
    # body-only changes in files with no dependents can be safely skipped.
    # Uses Array(String) instead of Set(String) for JSON serialization.
    # Nil when not available (old cache format or first compilation).
    @[JSON::Field(emit_null: false)]
    getter file_dependencies : Hash(String, Array(String))? = nil

    def initialize(@compiler_version : String, @codegen_target : String,
                   @flags : Array(String), @prelude : String,
                   @file_fingerprints : Hash(String, FileFingerprint),
                   @module_file_mapping : Hash(String, Array(String))? = nil,
                   @file_signatures : Hash(String, FileTopLevelSignature)? = nil,
                   @allocation_hints : AllocationHints? = nil,
                   @file_dependencies : Hash(String, Array(String))? = nil,
                   @build_settings : String = "",
                   @output : OutputStamp? = nil,
                   @external_macro_inputs : Hash(String, String?) = {} of String => String?,
                   @unverifiable_macro_inputs : Bool = false)
    end
  end

  # Manages file fingerprint cache data on disk for incremental compilation.
  # Follows the RequireWithTimestamp pattern from macros.cr and uses CacheDir
  # for storage location.
  module IncrementalCache
    CACHE_FILENAME = "incremental_cache.json"

    # External state read by macros, keyed by `<kind>:<argument>` with the
    # value observed during compilation. A build may only be skipped as a whole
    # if every recorded input still has the same value.
    module ExternalInput
      def self.env_key(name : String) : String
        "env:#{name}"
      end

      def self.system_key(command : String) : String
        "system:#{command}"
      end

      def self.file_exists(filename : String) : {String, String?}
        {"file_exists:#{File.expand_path(filename)}", File.exists?(filename).to_s}
      end

      def self.read_file(filename : String) : {String, String?}
        content_hash = begin
          Crystal::Digest::MD5.hexdigest(File.read(filename))
        rescue IO::Error
          nil
        end
        {"read_file:#{File.expand_path(filename)}", content_hash}
      end

      # The files of directory *path* (recursively), with their size and
      # modification time. Detects added, removed and edited files.
      def self.dir_tree(path : String) : {String, String?}
        expanded = File.expand_path(path)
        digest = begin
          Crystal::Digest::MD5.hexdigest do |ctx|
            Dir.glob(File.join(::Path[expanded].to_posix.to_s, "**", "*"), match: :dot_files).sort!.each do |entry|
              info = File.info?(entry)
              next unless info
              ctx.update entry
              ctx.update "\0"
              ctx.update "#{info.size}:#{info.modification_time.to_unix_ns}" unless info.directory?
              ctx.update "\0"
            end
          end
        rescue IO::Error
          nil
        end
        {"dir_tree:#{expanded}", digest}
      end

      # The input for a path a macro `run` program was given or declared:
      # a file's content, a directory's tree, or the absence of either.
      def self.path(path : String) : {String, String?}
        if File.file?(path)
          read_file(path)
        elsif Dir.exists?(path)
          dir_tree(path)
        else
          file_exists(path)
        end
      end

      # Whether all *inputs* still have the recorded value. Re-runs `system`
      # commands, which is cheap compared to the compilation it may avoid.
      def self.unchanged?(inputs : Hash(String, String?)) : Bool
        commands, others = inputs.partition { |key, _| key.starts_with?("system:") }
        return false unless others.all? { |key, value| current_value(key) == value }

        # The commands are independent subprocesses: run them concurrently.
        results = Channel(Bool).new(commands.size)
        commands.each do |key, value|
          spawn { results.send(current_value(key) == value) }
        end
        commands.size.times.all? { results.receive }
      end

      private def self.current_value(key : String) : String?
        kind, _, argument = key.partition(':')
        case kind
        when "env"         then ENV[argument]?
        when "file_exists" then file_exists(argument)[1]
        when "read_file"   then read_file(argument)[1]
        when "dir_tree"    then dir_tree(argument)[1]
        when "system"
          output = `#{argument}` rescue return "\0failed"
          $?.success? ? output : "\0failed"
        else
          "\0unknown"
        end
      end
    end

    # Load cache data from disk. Returns nil if missing, corrupt, or
    # version/target/flags mismatch.
    def self.load(cache_dir : String, compiler_version : String, codegen_target : String, flags : Array(String), prelude : String, build_settings : String) : IncrementalCacheData?
      path = File.join(cache_dir, CACHE_FILENAME)
      return nil unless File.exists?(path)

      data = IncrementalCacheData.from_json(File.read(path))

      # Invalidate if compiler version, target, flags, prelude or build settings changed
      return nil unless data.compiler_version == compiler_version
      return nil unless data.codegen_target == codegen_target
      return nil unless data.flags == flags
      return nil unless data.prelude == prelude
      return nil unless data.build_settings == build_settings

      data
    rescue JSON::ParseException
      nil
    rescue IO::Error
      nil
    end

    # Save cache data to disk as JSON.
    def self.save(cache_dir : String, data : IncrementalCacheData) : Nil
      Dir.mkdir_p(cache_dir)
      path = File.join(cache_dir, CACHE_FILENAME)
      File.write(path, data.to_json)
    rescue IO::Error
      # Best effort -- don't fail compilation if cache can't be written
    end

    # Compute a fingerprint for a single file using stat info and MD5 hash.
    def self.fingerprint(filename : String) : FileFingerprint
      info = File.info(filename)
      content = File.read(filename)
      content_hash = Crystal::Digest::MD5.hexdigest(content)

      FileFingerprint.new(
        filename: filename,
        mtime_epoch: info.modification_time.to_unix,
        content_hash: content_hash,
        byte_size: info.size,
      )
    end

    # Fast fingerprint using only stat info (mtime + size). Skips reading
    # file content and computing MD5 hash. Used on cold builds where no
    # prior fingerprint exists to compare against.
    def self.fingerprint_fast(filename : String) : FileFingerprint
      info = File.info(filename)
      FileFingerprint.new(
        filename: filename,
        mtime_epoch: info.modification_time.to_unix,
        content_hash: "",
        byte_size: info.size,
      )
    end

    # Compare old fingerprints against a current set of files.
    # Returns the set of filenames that have changed (new, modified, or removed).
    def self.changed_files(old_data : IncrementalCacheData, current_files : Set(String)) : Set(String)
      changed = Set(String).new

      # Check for new or modified files
      current_files.each do |filename|
        old_fp = old_data.file_fingerprints[filename]?

        if old_fp.nil?
          # New file not in previous cache
          changed.add(filename)
          next
        end

        # Quick check: stat-based (mtime + size) before expensive hash
        begin
          info = File.info(filename)
          if info.modification_time.to_unix != old_fp.mtime_epoch || info.size != old_fp.byte_size
            changed.add(filename)
          end
        rescue IO::Error
          changed.add(filename)
        end
      end

      # Files that were in old data but no longer present
      old_data.file_fingerprints.each_key do |filename|
        unless current_files.includes?(filename)
          changed.add(filename)
        end
      end

      changed
    end
  end

  # Extracts top-level structural signatures from the program's parsed AST.
  # This visitor walks the AST after parsing (before semantic mutation) and
  # collects type declarations, method signatures, include/extend statements,
  # constants, and top-level macro calls, grouped by source filename.
  #
  # The extracted signatures are used for Phase 6 incremental compilation:
  # if a file's content changed but its top-level signature is identical,
  # the change is "body-only" and dependent files may not need re-processing.
  class SignatureExtractor < Visitor
    # Per-file accumulated signatures.
    getter file_signatures : Hash(String, FileTopLevelSignature)

    # Intermediate per-file data collected during traversal.
    @type_decls = Hash(String, Array(TypeDeclarationSig)).new { |h, k| h[k] = [] of TypeDeclarationSig }
    @method_sigs = Hash(String, Array(MethodSig)).new { |h, k| h[k] = [] of MethodSig }
    @mixins = Hash(String, Array(String)).new { |h, k| h[k] = [] of String }
    @constants = Hash(String, Array(String)).new { |h, k| h[k] = [] of String }
    @macro_call_files = Set(String).new

    # Stack of type scope names for building fully-qualified names.
    @type_scope = [] of String

    # Nesting depth: when > 0, we are inside a def/macro body and should
    # not extract further signatures (TopLevelVisitor doesn't enter them either).
    @inside_def = 0

    def initialize
      @file_signatures = {} of String => FileTopLevelSignature
    end

    # Build the final FileTopLevelSignature map from collected data.
    # Call this after the visitor has processed the full AST.
    def build_signatures : Hash(String, FileTopLevelSignature)
      all_files = Set(String).new
      all_files.concat(@type_decls.keys)
      all_files.concat(@method_sigs.keys)
      all_files.concat(@mixins.keys)
      all_files.concat(@constants.keys)
      all_files.concat(@macro_call_files)

      all_files.each do |filename|
        @file_signatures[filename] = FileTopLevelSignature.new(
          type_declarations: @type_decls[filename]? || [] of TypeDeclarationSig,
          method_signatures: @method_sigs[filename]? || [] of MethodSig,
          mixins: @mixins[filename]? || [] of String,
          constants: @constants[filename]? || [] of String,
          has_top_level_macro_calls: @macro_call_files.includes?(filename),
        )
      end

      @file_signatures
    end

    private def current_scope_prefix : String
      @type_scope.empty? ? "" : @type_scope.join("::")
    end

    private def qualified_name(name : String) : String
      prefix = current_scope_prefix
      prefix.empty? ? name : "#{prefix}::#{name}"
    end

    private def filename_for(node : ASTNode) : String?
      node.location.try(&.original_filename)
    end

    def visit(node : ClassDef)
      return false if @inside_def > 0

      filename = filename_for(node)
      return true unless filename

      name = qualified_name(node.name.names.join("::"))
      kind = node.struct? ? "struct" : "class"
      parent = node.superclass.try(&.to_s)
      generic_params = node.type_vars || [] of String

      @type_decls[filename] << TypeDeclarationSig.new(
        name: name,
        kind: kind,
        parent: parent,
        generic_params: generic_params,
      )

      @type_scope.push(name)
      node.body.accept(self)
      @type_scope.pop

      false
    end

    def visit(node : ModuleDef)
      return false if @inside_def > 0

      filename = filename_for(node)
      return true unless filename

      name = qualified_name(node.name.names.join("::"))
      generic_params = node.type_vars || [] of String

      @type_decls[filename] << TypeDeclarationSig.new(
        name: name,
        kind: "module",
        parent: nil,
        generic_params: generic_params,
      )

      @type_scope.push(name)
      node.body.accept(self)
      @type_scope.pop

      false
    end

    def visit(node : EnumDef)
      return false if @inside_def > 0

      filename = filename_for(node)
      return true unless filename

      name = qualified_name(node.name.names.join("::"))
      base = node.base_type.try(&.to_s)

      @type_decls[filename] << TypeDeclarationSig.new(
        name: name,
        kind: "enum",
        parent: base,
        generic_params: [] of String,
      )

      # Enum members are constants -- extract member names as constants
      node.members.each do |member|
        if member.is_a?(Arg)
          @constants[filename] << qualified_name("#{node.name.names.join("::")}::#{member.name}")
        end
      end

      false
    end

    def visit(node : LibDef)
      return false if @inside_def > 0

      filename = filename_for(node)
      return true unless filename

      name = qualified_name(node.name.names.join("::"))

      @type_decls[filename] << TypeDeclarationSig.new(
        name: name,
        kind: "lib",
        parent: nil,
        generic_params: [] of String,
      )

      @type_scope.push(name)
      node.body.accept(self)
      @type_scope.pop

      false
    end

    def visit(node : Alias)
      return false if @inside_def > 0

      filename = filename_for(node)
      return true unless filename

      name = qualified_name(node.name.names.join("::"))
      value_str = node.value.to_s

      @type_decls[filename] << TypeDeclarationSig.new(
        name: name,
        kind: "alias",
        parent: value_str,
        generic_params: [] of String,
      )

      false
    end

    def visit(node : Def)
      return false if @inside_def > 0

      filename = filename_for(node)
      return false unless filename

      receiver_prefix = if (recv = node.receiver)
                          "#{recv.to_s}."
                        else
                          ""
                        end

      name = qualified_name("#{receiver_prefix}#{node.name}")

      arg_names = node.args.map(&.external_name)
      arg_restrictions = node.args.map { |arg| arg.restriction.try(&.to_s) }
      return_restriction = node.return_type.try(&.to_s)

      @method_sigs[filename] << MethodSig.new(
        name: name,
        arg_names: arg_names,
        arg_restrictions: arg_restrictions,
        return_restriction: return_restriction,
        is_abstract: node.abstract?,
      )

      # Do NOT descend into def body -- we only care about the signature
      false
    end

    def visit(node : Macro)
      return false if @inside_def > 0

      filename = filename_for(node)
      return false unless filename

      name = qualified_name(node.name)

      arg_names = node.args.map(&.external_name)
      arg_restrictions = node.args.map { |arg| arg.restriction.try(&.to_s) }

      @method_sigs[filename] << MethodSig.new(
        name: name,
        arg_names: arg_names,
        arg_restrictions: arg_restrictions,
        return_restriction: nil,
        is_abstract: false,
      )

      # Do NOT descend into macro body
      false
    end

    def visit(node : FunDef)
      return false if @inside_def > 0

      filename = filename_for(node)
      return false unless filename

      name = qualified_name(node.real_name.empty? ? node.name : node.real_name)

      arg_names = node.args.map(&.external_name)
      arg_restrictions = node.args.map { |arg| arg.restriction.try(&.to_s) }
      return_restriction = node.return_type.try(&.to_s)

      @method_sigs[filename] << MethodSig.new(
        name: name,
        arg_names: arg_names,
        arg_restrictions: arg_restrictions,
        return_restriction: return_restriction,
        is_abstract: false,
      )

      false
    end

    def visit(node : Include)
      return false if @inside_def > 0

      filename = filename_for(node)
      return false unless filename

      @mixins[filename] << "include #{node.name}"

      false
    end

    def visit(node : Extend)
      return false if @inside_def > 0

      filename = filename_for(node)
      return false unless filename

      @mixins[filename] << "extend #{node.name}"

      false
    end

    def visit(node : Assign)
      return false if @inside_def > 0

      # Only track constant assignments (target is a Path)
      if node.target.is_a?(Path)
        filename = filename_for(node)
        if filename
          target_path = node.target.as(Path)
          name = qualified_name(target_path.names.join("::"))
          @constants[filename] << name
        end
      end

      false
    end

    def visit(node : Call)
      return true if @inside_def > 0

      # A Call at the top level (outside defs) is a macro call.
      # Mark the file as having top-level macro calls.
      filename = filename_for(node)
      if filename
        @macro_call_files.add(filename)
      end

      # Continue traversal -- macro calls can expand to more definitions
      true
    end

    def visit(node : MacroExpression)
      return false if @inside_def > 0

      filename = filename_for(node)
      if filename
        @macro_call_files.add(filename)
      end

      false
    end

    def visit(node : MacroIf)
      return false if @inside_def > 0

      filename = filename_for(node)
      if filename
        @macro_call_files.add(filename)
      end

      # Visit both branches -- they might contain type/method defs
      true
    end

    def visit(node : MacroFor)
      return false if @inside_def > 0

      filename = filename_for(node)
      if filename
        @macro_call_files.add(filename)
      end

      true
    end

    def visit(node : AnnotationDef)
      return false if @inside_def > 0

      filename = filename_for(node)
      return false unless filename

      name = qualified_name(node.name.names.join("::"))

      @type_decls[filename] << TypeDeclarationSig.new(
        name: name,
        kind: "annotation",
        parent: nil,
        generic_params: [] of String,
      )

      false
    end

    def visit(node : VisibilityModifier)
      # Delegate to the inner expression
      node.exp.accept(self)
      false
    end

    def visit(node : Expressions)
      node.expressions.each(&.accept(self))
      false
    end

    def visit(node : Require)
      # Don't descend into requires -- they are handled separately
      false
    end

    # Default: visit children
    def visit(node : ASTNode)
      true
    end
  end

  # Compares two FileTopLevelSignature values and determines the kind of change.
  enum SignatureChangeKind
    # No change in signature -- body-only modification.
    BodyOnly

    # Structural change -- signature differs, dependent files need re-processing.
    Structural
  end

  module IncrementalCache
    # Compare old vs new FileTopLevelSignature for a single file.
    # Returns BodyOnly if signatures are identical, Structural if they differ.
    # Files with has_top_level_macro_calls always count as Structural.
    def self.compare_signatures(old_sig : FileTopLevelSignature, new_sig : FileTopLevelSignature) : SignatureChangeKind
      # Files with top-level macro calls always count as structural changes
      # because macros can generate arbitrary types and methods.
      if new_sig.has_top_level_macro_calls || old_sig.has_top_level_macro_calls
        return SignatureChangeKind::Structural
      end

      # Compare all structural components
      return SignatureChangeKind::Structural unless old_sig.type_declarations == new_sig.type_declarations
      return SignatureChangeKind::Structural unless old_sig.method_signatures == new_sig.method_signatures
      return SignatureChangeKind::Structural unless old_sig.mixins == new_sig.mixins
      return SignatureChangeKind::Structural unless old_sig.constants == new_sig.constants

      SignatureChangeKind::BodyOnly
    end

    # Classify all changed files into body-only vs structural changes.
    # Returns a tuple of {body_only_files, structural_files}.
    # Files not present in the old signatures are always classified as structural.
    def self.classify_changes(
      changed_files : Set(String),
      old_signatures : Hash(String, FileTopLevelSignature)?,
      new_signatures : Hash(String, FileTopLevelSignature),
    ) : {Set(String), Set(String)}
      body_only = Set(String).new
      structural = Set(String).new

      changed_files.each do |filename|
        new_sig = new_signatures[filename]?
        old_sig = old_signatures.try(&.[filename]?)

        if old_sig && new_sig
          case compare_signatures(old_sig, new_sig)
          when .body_only?
            body_only.add(filename)
          when .structural?
            structural.add(filename)
          end
        else
          # New file or file removed from signatures -- always structural
          structural.add(filename)
        end
      end

      {body_only, structural}
    end
  end

  # In-memory cache of parsed ASTs keyed by filename and content hash.
  # Used in the watch loop to skip re-parsing files that haven't changed.
  #
  # IMPORTANT: Cached ASTs must be cloned before reuse because semantic
  # analysis mutates AST nodes in place (sets types, expands macros,
  # binds nodes). ASTNode#clone performs a deep copy with location
  # preservation.
  class ParseCache
    @cache = {} of String => {content_hash: String, ast: ASTNode}
    @hits = 0
    @misses = 0

    # Returns a cloned AST if the file is cached and the content hash matches.
    # Returns nil on cache miss (file not cached or content changed).
    def get(filename : String, current_content_hash : String) : ASTNode?
      entry = @cache[filename]?
      unless entry
        @misses += 1
        return nil
      end

      unless entry[:content_hash] == current_content_hash
        @misses += 1
        return nil
      end

      @hits += 1
      entry[:ast].clone # MUST clone - semantic mutates AST nodes in place
    end

    # Store a parsed AST in the cache. The AST should be cloned before
    # storing if it will be mutated after this call.
    def store(filename : String, content_hash : String, ast : ASTNode) : Nil
      @cache[filename] = {content_hash: content_hash, ast: ast}
    end

    # Remove all cached entries.
    def clear : Nil
      @cache.clear
      @hits = 0
      @misses = 0
    end

    # Number of files currently cached.
    def size : Int32
      @cache.size
    end

    # Number of cache hits since last clear.
    def hits : Int32
      @hits
    end

    # Number of cache misses since last clear.
    def misses : Int32
      @misses
    end

    # Reset hit/miss counters (called between compilations).
    def reset_stats : Nil
      @hits = 0
      @misses = 0
    end

    # Total lookups (hits + misses).
    def total_lookups : Int32
      @hits + @misses
    end

    # Hit rate as a percentage, or 0.0 if no lookups.
    def hit_rate : Float64
      total = total_lookups
      return 0.0 if total == 0
      (@hits.to_f64 / total.to_f64) * 100.0
    end
  end
end
