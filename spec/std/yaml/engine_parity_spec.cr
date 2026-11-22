require "spec"
require "yaml"

# Results that must be identical on the Mica engine (the default, see
# doc/yaml_mica.md) and on libyaml (`-Duse_libyaml`). The expected values
# were recorded from libyaml 0.2.5.
describe "YAML engines" do
  it "states the libyaml version the Mica engine follows" do
    {% if flag?(:use_libyaml) %}
      YAML.libyaml_version.should be >= SemanticVersion.new(0, 1, 0)
    {% else %}
      YAML.libyaml_version.should eq SemanticVersion.new(0, 2, 5)
    {% end %}
  end

  it "runs on the engine the build selected" do
    {% if flag?(:use_libyaml) %}
      {{ YAML.has_constant?(:MicaEngine) }}.should be_false
      {{ @top_level.has_constant?(:LibYAML) }}.should be_true
    {% else %}
      {{ YAML.has_constant?(:MicaEngine) }}.should be_true
      {{ @top_level.has_constant?(:LibYAML) }}.should be_false
    {% end %}
  end

  it "reports a syntax error with the same message, line, column and context" do
    error = expect_raises(YAML::ParseException) { YAML.parse("a: [1, 2\nb: 3\n") }
    error.message.should eq "did not find expected ',' or ']' at line 2, column 2, while parsing a flow sequence at line 1, column 4"
    error.line_number.should eq 2
    error.column_number.should eq 2
  end

  it "reports invalid UTF-8 at line 1, column 1" do
    error = expect_raises(YAML::ParseException) { YAML.parse("a: \xff\n") }
    error.line_number.should eq 1
    error.column_number.should eq 1
  end

  it "reads the same marks from a String and from an IO" do
    source = "---\nkey: &a [1, two]\nother: *a\n...\n"
    [YAML::PullParser.new(source), YAML::PullParser.new(IO::Memory.new(source))].each do |parser|
      list_of_marks = [] of {YAML::EventKind, Int32, Int32, Int32, Int32}
      loop do
        list_of_marks << {parser.kind, parser.start_line.to_i, parser.start_column.to_i, parser.end_line.to_i, parser.end_column.to_i}
        break if parser.kind.stream_end?
        parser.read_next
      end
      list_of_marks.size.should eq 13
      list_of_marks[4].should eq({YAML::EventKind::SEQUENCE_START, 2, 6, 2, 10})
      list_of_marks[7].should eq({YAML::EventKind::SEQUENCE_END, 2, 16, 2, 17})
      list_of_marks[9].should eq({YAML::EventKind::ALIAS, 3, 8, 3, 10})
    end
  end

  it "applies merge keys, anchors and the core schema" do
    yaml = YAML.parse("base: &base {host: localhost, port: 3000}\ndev:\n  <<: *base\n  port: 0x10\n  empty: ~\n")
    yaml["dev"]["host"].as_s.should eq "localhost"
    yaml["dev"]["port"].as_i.should eq 16
    yaml["dev"]["empty"].raw.should be_nil
  end

  it "writes the same text" do
    value = {"name" => "mica", "list" => ["a", "multi\nline", "", "trés: bien"], "nested" => {"n" => 1, "t" => true}}
    value.to_yaml.should eq "---\nname: mica\nlist:\n- a\n- 'multi\n\n  line'\n- \"\"\n- 'trés: bien'\nnested:\n  n: 1\n  t: true\n"
  end

  it "stops a billion-laughs document (GHSA-gmv7-hhm8-cxj5)" do
    bomb = String.build do |io|
      io << "a0: &a0 [x, x, x, x, x, x, x, x, x]\n"
      (1..9).each do |level|
        io << 'a' << level << ": &a" << level << " ["
        9.times { |index| io << (index == 0 ? "" : ", ") << "*a" << (level - 1) }
        io << "]\n"
      end
    end
    expect_raises(YAML::ParseException, "excessive aliasing") { YAML.parse(bomb) }
  end
end
