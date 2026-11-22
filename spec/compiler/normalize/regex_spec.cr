require "../../spec_helper"

private def assert_expand_regex_const(from : String, to, *, flags = nil, file = __FILE__, line = __LINE__)
  from_nodes = Parser.parse(from)
  assert_expand(from_nodes, flags: flags, file: file, line: line) do |to_nodes, program|
    const = program.types[to_nodes.to_s].should be_a(Crystal::Const), file: file, line: line
    const.value.to_s.should eq(to.strip), file: file, line: line
  end
end

describe "Normalize: regex literal" do
  describe "StringLiteral" do
    it "expands to const" do
      assert_expand Parser.parse(%q(/foo/)) do |to_nodes, program|
        to_nodes.to_s.should eq "$Regex:0"
      end
    end

    it "simple" do
      assert_expand_regex_const %q(/foo/), <<-'CRYSTAL'
      ::Regex.new("foo", ::Regex::Options.new(0))
      CRYSTAL
    end
  end

  describe "StringInterpolation" do
    it "simple" do
      assert_expand %q(/#{"foo".to_s}/), <<-'CRYSTAL'
        ::Regex.new("#{"foo".to_s}", ::Regex::Options.new(0))
        CRYSTAL
    end
  end

  describe "options" do
    it "empty" do
      assert_expand_regex_const %q(//), <<-'CRYSTAL'
      ::Regex.new("", ::Regex::Options.new(0))
      CRYSTAL
    end
    it "i" do
      assert_expand_regex_const %q(//i), <<-'CRYSTAL'
      ::Regex.new("", ::Regex::Options.new(1))
      CRYSTAL
    end
    it "x" do
      assert_expand_regex_const %q(//x), <<-'CRYSTAL'
      ::Regex.new("", ::Regex::Options.new(8))
      CRYSTAL
    end
    it "im" do
      assert_expand_regex_const %q(//im), <<-'CRYSTAL'
      ::Regex.new("", ::Regex::Options.new(7))
      CRYSTAL
    end
    it "imx" do
      assert_expand_regex_const %q(//imx), <<-'CRYSTAL'
      ::Regex.new("", ::Regex::Options.new(15))
      CRYSTAL
    end
  end
  describe "on the Mica engine (the default)" do
    it "expands a literal inside the Mica dialect" do
      assert_expand_regex_const %q(/(?<year>\d{4})-(?:a|b)+/i), <<-'CRYSTAL'
      ::Regex.new("(?<year>\\d{4})-(?:a|b)+", ::Regex::Options.new(1))
      CRYSTAL
    end

    it "rejects a literal the Mica engine leaves out and names -Duse_pcre2" do
      expect_raises(Crystal::TypeException, "invalid regex for the Mica regex engine: lookahead (at 1) is not supported; build with -Duse_pcre2 to run this pattern on PCRE2") do
        assert_expand(Parser.parse(%q(/a(?=b)/))) { }
      end
      expect_raises(Crystal::TypeException, "invalid regex for the Mica regex engine: a backreference (at 3)") do
        assert_expand(Parser.parse(%q(/(a)\1/))) { }
      end
    end

    it "reads the literal options" do
      expect_raises(Crystal::TypeException, "invalid regex for the Mica regex engine") do
        assert_expand(Parser.parse(%q(/a (?=b)/x))) { }
      end
    end

    it "accepts -Duse_mica as the default" do
      assert_expand_regex_const %q(/a+b/), <<-'CRYSTAL', flags: "use_mica"
      ::Regex.new("a+b", ::Regex::Options.new(0))
      CRYSTAL
      expect_raises(Crystal::TypeException, "invalid regex for the Mica regex engine") do
        assert_expand(Parser.parse(%q(/a(?=b)/)), flags: "use_mica") { }
      end
    end
  end

  describe "with -Duse_pcre2 or -Duse_pcre" do
    it "leaves the literal to the PCRE2 engine" do
      assert_expand_regex_const %q(/a(?=b)/), <<-'CRYSTAL', flags: "use_pcre2"
      ::Regex.new("a(?=b)", ::Regex::Options.new(0))
      CRYSTAL
    end

    it "leaves the literal to the legacy PCRE engine" do
      assert_expand_regex_const %q(/(a)\1/), <<-'CRYSTAL', flags: "use_pcre"
      ::Regex.new("(a)\\1", ::Regex::Options.new(0))
      CRYSTAL
    end

    it "selects PCRE over -Duse_mica when both are given" do
      assert_expand_regex_const %q(/a(?=b)/), <<-'CRYSTAL', flags: "use_mica use_pcre2"
      ::Regex.new("a(?=b)", ::Regex::Options.new(0))
      CRYSTAL
    end
  end
end
