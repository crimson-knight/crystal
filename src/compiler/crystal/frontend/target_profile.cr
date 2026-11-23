require "json"

module Crystal
  # What the frontend needs to know about a target that it cannot ask the
  # machine it runs on: the target triple, flags the target's builds always
  # define, and the output of the shell commands the target's std library runs
  # at macro time (for example `pkg-config bdw-gc --modversion`).
  #
  # A profile is recorded once on a machine of the target's kind (see
  # `scripts/record_target_profile.rb`) and shipped beside the bundled std
  # library, so a WASI or browser build can type check for macOS or Linux.
  struct FrontendTargetProfile
    include JSON::Serializable

    getter target : String
    getter list_of_flags : Array(String) = [] of String
    getter macro_shell_answers_by_command : Hash(String, String) = {} of String => String

    def initialize(@target, @list_of_flags = [] of String, @macro_shell_answers_by_command = {} of String => String)
    end

    def self.load(path : String) : self
      from_json(File.read(path))
    end

    def apply(program : Program) : Nil
      program.flags.concat(list_of_flags)
      program.macro_shell_answers_by_command = macro_shell_answers_by_command
    end
  end
end
