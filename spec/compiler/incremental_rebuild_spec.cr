require "../spec_helper"

describe "Compiler with --incremental" do
  it "rebuilds an edited program while it skips the modules of unchanged files" do
    with_tempfile("edited_program") do |directory|
      Dir.mkdir_p(directory)
      helper = File.join(directory, "helper.cr")
      program = File.join(directory, "program.cr")
      executable = File.join(directory, "program")
      File.write(helper, "module Helper\n  def self.value\n    1\n  end\nend\n")
      File.write(program, %(require "./helper"\nputs Helper.value\n))
      command = ["build", "--incremental"].concat(program_flags_options).concat([program, "-o", executable])

      Crystal::Command.run command
      Process.capture(executable).should eq("1\n")

      File.write(helper, "module Helper\n  def self.value\n    999\n  end\nend\n")
      File.touch(helper, Time.utc + 5.seconds)
      Crystal::Command.run command
      Process.capture(executable).should eq("999\n")

      Crystal::Command.run command
      Process.capture(executable).should eq("999\n")
    end
  end
end
