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
      expect_raises(Crystal::TypeException, "invalid regex for the Mica regex engine: lookahead (at 1) is not supported. Build with -Duse_pcre2 to run this pattern on PCRE2. See doc/regex_mica.md for rewrites.") do
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

    # Grant shipped this pattern as `Grant::Query::JoinSupport::RAW_JOIN_TARGET`
    # through 0.23.4. Every app that used Grant joins reached it, so on a
    # compiler whose default engine is Mica the app's build stops here: the
    # message has to name the construct, where it starts, and the way out.
    it "rejects the lookahead in Grant's RAW_JOIN_TARGET and names -Duse_pcre2" do
      grant_raw_join_target = %q(/\bJOIN\s+([A-Za-z_][A-Za-z0-9_]*)(?:\s+(?:AS\s+)?(?!ON\b|USING\b|INNER\b|LEFT\b|RIGHT\b|FULL\b|CROSS\b|NATURAL\b|JOIN\b)([A-Za-z_][A-Za-z0-9_]*))?/i)

      error = expect_raises(Crystal::TypeException) do
        assert_expand(Parser.parse(grant_raw_join_target)) { }
      end
      error.message.should eq("invalid regex for the Mica regex engine: lookahead (at 49) is not supported. Build with -Duse_pcre2 to run this pattern on PCRE2. See doc/regex_mica.md for rewrites.")

      assert_expand_regex_const grant_raw_join_target, <<-'CRYSTAL', flags: "use_pcre2"
      ::Regex.new("\\bJOIN\\s+([A-Za-z_][A-Za-z0-9_]*)(?:\\s+(?:AS\\s+)?(?!ON\\b|USING\\b|INNER\\b|LEFT\\b|RIGHT\\b|FULL\\b|CROSS\\b|NATURAL\\b|JOIN\\b)([A-Za-z_][A-Za-z0-9_]*))?", ::Regex::Options.new(1))
      CRYSTAL
    end

    it "names the shard and the upgrade when Grant's RAW_JOIN_TARGET comes from lib/grant" do
      grant_raw_join_target = %q(/\bJOIN\s+([A-Za-z_][A-Za-z0-9_]*)(?:\s+(?:AS\s+)?(?!ON\b|USING\b|INNER\b|LEFT\b|RIGHT\b|FULL\b|CROSS\b|NATURAL\b|JOIN\b)([A-Za-z_][A-Za-z0-9_]*))?/i)
      from_nodes = parse(grant_raw_join_target, filename: "/apps/blog/lib/grant/src/grant/query/joins.cr")

      error = expect_raises(Crystal::TypeException) do
        assert_expand(from_nodes) { }
      end
      error.message.should eq("invalid regex for the Mica regex engine: lookahead (at 49) is not supported. " \
                              "The pattern is in the shard 'grant' (lib/grant/src/grant/query/joins.cr). " \
                              "Upgrade grant to a release built for Mica (update its pin in shard.yml, then run shards update grant), " \
                              "or build with -Duse_pcre2 to run this pattern on PCRE2. See doc/regex_mica.md for rewrites.")
    end

    it "keeps the app's own literal free of shard advice" do
      error = expect_raises(Crystal::TypeException) do
        assert_expand(parse(%q(/a(?=b)/), filename: "/apps/blog/src/blog.cr")) { }
      end
      error.message.should eq("invalid regex for the Mica regex engine: lookahead (at 1) is not supported. Build with -Duse_pcre2 to run this pattern on PCRE2. See doc/regex_mica.md for rewrites.")
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

describe Crystal::MicaRegexLiteral do
  describe ".shard_file?" do
    it "finds the shard in an absolute path" do
      shard_file = Crystal::MicaRegexLiteral.shard_file?("/apps/blog/lib/grant/src/grant/query/joins.cr").should_not be_nil
      shard_file.shard_name.should eq("grant")
      shard_file.path.should eq("lib/grant/src/grant/query/joins.cr")
    end

    it "finds the shard in a relative path" do
      shard_file = Crystal::MicaRegexLiteral.shard_file?("lib/grant/src/grant.cr").should_not be_nil
      shard_file.shard_name.should eq("grant")
      shard_file.path.should eq("lib/grant/src/grant.cr")
    end

    it "takes the innermost shard of a nested lib path" do
      shard_file = Crystal::MicaRegexLiteral.shard_file?("/apps/blog/lib/amber/lib/grant/src/grant.cr").should_not be_nil
      shard_file.shard_name.should eq("grant")
      shard_file.path.should eq("lib/grant/src/grant.cr")
    end

    it "returns nil for the app's own file" do
      Crystal::MicaRegexLiteral.shard_file?("/apps/blog/src/models/post.cr").should be_nil
      Crystal::MicaRegexLiteral.shard_file?("/apps/blog/lib/tasks.cr").should be_nil
    end

    it "returns nil without a location" do
      Crystal::MicaRegexLiteral.shard_file?(nil).should be_nil
    end
  end

  describe ".error?" do
    it "keeps a parse error's detail and adds the shard sentence for a shard file" do
      Crystal::MicaRegexLiteral.error?("a{2,1}", Regex::CompileOptions::None, "/apps/blog/lib/tidy/src/tidy.cr").should eq(
        "numbers out of order in {} quantifier at 5. " \
        "The pattern is in the shard 'tidy' (lib/tidy/src/tidy.cr). " \
        "Upgrade tidy to a release built for Mica (update its pin in shard.yml, then run shards update tidy), " \
        "or build with -Duse_pcre2 to run this pattern on PCRE2. See doc/regex_mica.md for rewrites.")
    end

    it "keeps a parse error's detail alone for the app's own file" do
      Crystal::MicaRegexLiteral.error?("a{2,1}", Regex::CompileOptions::None, "/apps/blog/src/blog.cr").should eq("numbers out of order in {} quantifier at 5")
      Crystal::MicaRegexLiteral.error?("a{2,1}", Regex::CompileOptions::None).should eq("numbers out of order in {} quantifier at 5")
    end
  end
end
