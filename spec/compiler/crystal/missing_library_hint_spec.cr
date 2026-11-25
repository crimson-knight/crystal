require "../../spec_helper"

describe Crystal::MissingLibraryHint do
  it "names the flag and the Homebrew formula for a library the linker reports missing" do
    hint = Crystal::MissingLibraryHint.new(installed_by_homebrew: true)
    hint.read("ld: library 'pcre2-8' not found\n")

    hint.any_known_library_missing?.should be_true
    hint.to_s.should eq <<-TEXT
      The linker needs libpcre2-8 because the program was built with -Duse_pcre2 (Regex on PCRE2).
        Install it with: brew install pcre2
        Build without -Duse_pcre2 to run Regex on Mica, which needs no C library.

      TEXT
  end

  it "reads the message of every linker the compiler drives" do
    hint = Crystal::MissingLibraryHint.new(installed_by_homebrew: true)
    hint.read("ld.lld: error: unable to find library -lyaml\n")
    hint.read("/usr/bin/ld: cannot find -lgmp: No such file or directory\n")
    hint.read("ld64.lld: error: library not found for -levent\n")

    hint.list_of_missing_libraries.should eq ["yaml", "gmp", "event"]
  end

  it "names a package for each platform when the compiler is not a Homebrew keg" do
    hint = Crystal::MissingLibraryHint.new(installed_by_homebrew: false)
    hint.read("/usr/bin/ld: cannot find -lyaml\n")

    hint.to_s.should contain "brew install libyaml (macOS) or apt install libyaml-dev (Debian, Ubuntu)"
  end

  it "explains a formula once when it provides two missing libraries" do
    hint = Crystal::MissingLibraryHint.new(installed_by_homebrew: true)
    hint.read("ld: library 'ssl' not found\n")
    hint.read("ld: library 'crypto' not found\n")

    hint.to_s.scan("brew install openssl@3").size.should eq 1
  end

  it "leaves a library it does not know to the linker's own message" do
    hint = Crystal::MissingLibraryHint.new(installed_by_homebrew: true)
    hint.read("ld: library 'foo_bar' not found\n")

    hint.list_of_missing_libraries.should eq ["foo_bar"]
    hint.any_known_library_missing?.should be_false
    hint.to_s.should eq ""
  end
end
