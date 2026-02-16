require "json"

module Crystal
  # Fingerprint of a single source file for incremental compilation tracking.
  # Includes mtime, content hash, and byte size for fast change detection.
  record FileFingerprint,
    filename : String,
    mtime_epoch : Int64,
    content_hash : String,
    byte_size : Int64 do
    include JSON::Serializable
  end

  # Serializable cache data written to disk between compilations.
  # Tracks compiler version, target, flags, and per-file fingerprints
  # so the cache can be invalidated when any of these change.
  record IncrementalCacheData,
    compiler_version : String,
    codegen_target : String,
    flags : Array(String),
    prelude : String,
    file_fingerprints : Hash(String, FileFingerprint) do
    include JSON::Serializable
  end

  # Manages file fingerprint cache data on disk for incremental compilation.
  # Follows the RequireWithTimestamp pattern from macros.cr and uses CacheDir
  # for storage location.
  module IncrementalCache
    CACHE_FILENAME = "incremental_cache.json"

    # Load cache data from disk. Returns nil if missing, corrupt, or
    # version/target/flags mismatch.
    def self.load(cache_dir : String, compiler_version : String, codegen_target : String, flags : Array(String), prelude : String) : IncrementalCacheData?
      path = File.join(cache_dir, CACHE_FILENAME)
      return nil unless File.exists?(path)

      data = IncrementalCacheData.from_json(File.read(path))

      # Invalidate if compiler version, target, flags, or prelude changed
      return nil unless data.compiler_version == compiler_version
      return nil unless data.codegen_target == codegen_target
      return nil unless data.flags == flags
      return nil unless data.prelude == prelude

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
