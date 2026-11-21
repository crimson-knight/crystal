require "../spec_helper"

{% if Regex::Engine.resolve.name == "Regex::MicaEngine" %}
  describe "Regex::MicaEngine" do
    it "names itself and the PCRE2 dialect it reads" do
      Regex::Engine.version.should start_with("Mica ")
      Regex::Engine.version_number.should eq({10, 49})
    end

    it "raises UnsupportedSyntaxError for a construct Mica leaves out" do
      error = expect_raises(Regex::UnsupportedSyntaxError, "lookahead is not supported by the Mica regex engine at 1") do
        Regex.new("a(?=b)")
      end
      error.construct.should eq("lookahead")
      error.byte_offset.should eq(1)
      error.should be_a(ArgumentError)
    end

    it "reports an unsupported construct from .error?" do
      Regex.error?("(a)\\1").should_not be_nil
      Regex.error?("(?<=a)b").should_not be_nil
      Regex.error?("(a)(?:b)").should be_nil
    end

    it "matches in time linear in the haystack" do
      haystack = "a" * 40_000 + "b"
      /(a+)+$/.matches?(haystack).should be_false
      /(a+)+b/.matches?(haystack).should be_true
      /(a|aa)+c/.matches?(haystack).should be_false
      /^(\w+\s?)*$/.matches?("a" * 5_000 + "!").should be_false
    end

    it "keeps group offsets, names and duplicate names" do
      match = /(?<word>\w+)|(?<number>\d+)/.match("  héllo").should_not be_nil
      match["word"].should eq("héllo")
      match["number"]?.should be_nil
      match.begin.should eq(2)
      match.byte_end.should eq(8)

      duplicate = /(?<x>a)|(?<x>b)/.match("b").should_not be_nil
      duplicate["x"].should eq("b")
    end

    it "does not support MATCH_INVALID_UTF" do
      Regex.supports_compile_options?(:match_invalid_utf).should be_false
      expect_raises(ArgumentError, "MATCH_INVALID_UTF") do
        Regex.new("a", options: Regex::CompileOptions::MATCH_INVALID_UTF)
      end
    end

    it "searches the runs of valid UTF-8 under NO_UTF_CHECK" do
      match = "ab\xFFcd".match(/c./, options: Regex::MatchOptions::NO_UTF_CHECK).should_not be_nil
      match.byte_begin.should eq(3)
      match[0].should eq("cd")
      "ab\xFFcd".matches?(/b.c/, options: Regex::MatchOptions::NO_UTF_CHECK).should be_false
      "ab\xFFcd".matches?(/^c/, options: Regex::MatchOptions::NO_UTF_CHECK).should be_false
      "ab\xFFcd".matches?(/\bc/, options: Regex::MatchOptions::NO_UTF_CHECK).should be_true
    end

    it "raises ArgumentError for invalid UTF-8 without NO_UTF_CHECK" do
      expect_raises(ArgumentError, "UTF-8 error") do
        "ab\xFFcd".matches?(/c/)
      end
    end
  end
{% end %}
