require "./spec_helper"

describe "`crystal tool strict`" do
  it "converts a file and exits 0; a second run with --check finds nothing" do
    with_tempfile("tool_strict_cli.cr") do |path|
      File.write(path, <<-CRYSTAL)
        def twice(value)
          value
        end

        twice(1)
        CRYSTAL

      Process.capture_result(crystal, "tool", "strict", "--prelude", "empty", path)
        .should(be_success)
        .output.should(contain "1 methods typed")
      File.read(path).should eq("# crystal: strict\ndef twice(value : Int32) : Int32\n  value\nend\n\ntwice(1)\n")

      Process.capture_result(crystal, "tool", "strict", "--prelude", "empty", "--check", path)
        .should(be_success)
        .output.should(contain "unchanged")
    end
  end

  it "exits 1 with --check when a file would change" do
    with_tempfile("tool_strict_cli_check.cr") do |path|
      source = "def twice(value)\n  value\nend\n\ntwice(1)\n"
      File.write(path, source)

      Process.capture_result(crystal, "tool", "strict", "--prelude", "empty", "--check", path)
        .should_not(be_success)
      File.read(path).should eq(source)
    end
  end
end
