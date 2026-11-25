module Crystal
  # Explains a C library the linker could not find: what in the program asked for
  # it, how to install it, and how to build without it.
  #
  # Regex, YAML, text encodings and compression run on Mica by default, so a program
  # needs their C libraries only when a flag asks for them. The Homebrew formula
  # installs none of those libraries; this hint tells the person who passed the flag
  # what to install.
  struct MissingLibraryHint
    # A C library the standard library can link, and how a program comes to need it.
    record KnownLibrary,
      reason : String,
      homebrew_formula : String,
      debian_package : String,
      way_without_it : String

    LIST_OF_KNOWN_LIBRARIES = {
      "pcre2-8" => KnownLibrary.new(
        reason: "the program was built with -Duse_pcre2 (Regex on PCRE2)",
        homebrew_formula: "pcre2",
        debian_package: "libpcre2-dev",
        way_without_it: "Build without -Duse_pcre2 to run Regex on Mica, which needs no C library."),
      "pcre" => KnownLibrary.new(
        reason: "the program was built with -Duse_pcre (Regex on PCRE1)",
        homebrew_formula: "pcre",
        debian_package: "libpcre3-dev",
        way_without_it: "Build without -Duse_pcre to run Regex on Mica, which needs no C library."),
      "yaml" => KnownLibrary.new(
        reason: "the program was built with -Duse_libyaml (YAML on libyaml)",
        homebrew_formula: "libyaml",
        debian_package: "libyaml-dev",
        way_without_it: "Build without -Duse_libyaml to run YAML on Mica, which needs no C library."),
      "z" => KnownLibrary.new(
        reason: "the program was built with -Duse_libz (Compress on zlib)",
        homebrew_formula: "zlib",
        debian_package: "zlib1g-dev",
        way_without_it: "Build without -Duse_libz to run Compress on Mica, which needs no C library."),
      "iconv" => KnownLibrary.new(
        reason: "the program was built with -Duse_libiconv or -Duse_iconv (String#encode on iconv)",
        homebrew_formula: "libiconv",
        debian_package: "libc6-dev",
        way_without_it: "Build without the iconv flag to run String#encode on Mica, which needs no C library."),
      "event" => KnownLibrary.new(
        reason: "the program was built with -Devloop=libevent",
        homebrew_formula: "libevent",
        debian_package: "libevent-dev",
        way_without_it: "Build without -Devloop=libevent to use the default event loop, which needs no C library."),
      "event_pthreads" => KnownLibrary.new(
        reason: "the program was built with -Devloop=libevent",
        homebrew_formula: "libevent",
        debian_package: "libevent-dev",
        way_without_it: "Build without -Devloop=libevent to use the default event loop, which needs no C library."),
      "gmp" => KnownLibrary.new(
        reason: %(the program requires "big" (BigInt, BigFloat, BigRational, BigDecimal)),
        homebrew_formula: "gmp",
        debian_package: "libgmp-dev",
        way_without_it: %(A program that leaves out require "big" needs no GMP.)),
      "ssl" => KnownLibrary.new(
        reason: %(the program uses TLS or OpenSSL (require "openssl", an HTTPS client or server)),
        homebrew_formula: "openssl@3",
        debian_package: "libssl-dev",
        way_without_it: "A program built with -Dwithout_openssl links no OpenSSL and has no TLS."),
      "crypto" => KnownLibrary.new(
        reason: %(the program uses OpenSSL's libcrypto (TLS, or Digest::SHA256 and SHA512)),
        homebrew_formula: "openssl@3",
        debian_package: "libssl-dev",
        way_without_it: "A program built with -Dwithout_openssl links no OpenSSL and has no TLS."),
      "xml2" => KnownLibrary.new(
        reason: %(the program requires "xml"),
        homebrew_formula: "libxml2",
        debian_package: "libxml2-dev",
        way_without_it: %(A program that leaves out require "xml" needs no libxml2.)),
      "sqlite3" => KnownLibrary.new(
        reason: "the program uses SQLite through a C driver",
        homebrew_formula: "sqlite",
        debian_package: "libsqlite3-dev",
        way_without_it: "A program that uses no SQLite driver needs no libsqlite3."),
    }

    LIST_OF_LINKER_MESSAGES = {
      /cannot find -l(\S+)\b/,
      /unable to find library -l(\S+)\b/,
      /library not found for -l(\S+)\b/,
      /library '(\S+)' not found/,
    }

    getter list_of_missing_libraries = [] of String

    def initialize(@installed_by_homebrew : Bool = MissingLibraryHint.installed_by_homebrew?)
    end

    # Records each library a line of linker output reports as missing.
    def read(line : String) : Nil
      LIST_OF_LINKER_MESSAGES.each do |pattern|
        line.scan(pattern) do |match|
          library_name = match[1]
          @list_of_missing_libraries << library_name unless @list_of_missing_libraries.includes?(library_name)
        end
      end
    end

    def any_known_library_missing? : Bool
      @list_of_missing_libraries.any? { |library_name| LIST_OF_KNOWN_LIBRARIES.has_key?(library_name) }
    end

    # The explanation for every missing library this hint knows, one paragraph each.
    def to_s(io : IO) : Nil
      list_of_explained_formulas = [] of String
      @list_of_missing_libraries.each do |library_name|
        known_library = LIST_OF_KNOWN_LIBRARIES[library_name]?
        next unless known_library
        next if list_of_explained_formulas.includes?(known_library.homebrew_formula)
        list_of_explained_formulas << known_library.homebrew_formula

        io << "The linker needs lib" << library_name << " because " << known_library.reason << ".\n"
        if @installed_by_homebrew
          io << "  Install it with: brew install " << known_library.homebrew_formula << '\n'
        else
          io << "  Install it with your package manager, for example: brew install " << known_library.homebrew_formula
          io << " (macOS) or apt install " << known_library.debian_package << " (Debian, Ubuntu)\n"
        end
        io << "  " << known_library.way_without_it << '\n'
      end
    end

    # True when this compiler runs from a Homebrew keg, whose formula leaves the
    # optional C libraries for the person to install.
    def self.installed_by_homebrew? : Bool
      executable_path = Process.executable_path
      return false unless executable_path
      real_path = begin
        File.realpath(executable_path)
      rescue File::Error
        executable_path
      end
      real_path.includes?("/Cellar/")
    end
  end
end
