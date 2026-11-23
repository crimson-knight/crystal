require "../spec_helper"

# Development builds skip `dsymutil` on macOS; the backtraces below need the
# `.dwarf` file it writes to show file and line numbers.
CALL_STACK_SPEC_BUILD_FLAGS = %w(--dsymutil)

describe "Backtrace" do
  it "prints file line:column", tags: %w[slow] do
    source_file = datapath("backtrace_sample")

    # CallStack tries to make files relative to the current dir,
    # so we do the same for tests
    current_dir = Dir.current
    current_dir += File::SEPARATOR unless current_dir.ends_with?(File::SEPARATOR)
    source_file = source_file.lchop(current_dir)

    _, output, _ = compile_and_run_file(source_file, CALL_STACK_SPEC_BUILD_FLAGS)

    # resolved file:line:column (no column for MSVC PDB because of poor support
    # by external tooling in general)
    {% if flag?(:msvc) %}
      output.should match(/^#{Regex.escape(source_file)}:3 in 'callee1'/m)
      output.should match(/^#{Regex.escape(source_file)}:13 in 'callee3'/m)
    {% else %}
      output.should match(/^#{Regex.escape(source_file)}:3:10 in 'callee1'/m)
      output.should match(/^#{Regex.escape(source_file)}:13:5 in 'callee3'/m)
    {% end %}

    # skipped internal details
    output.should_not contain("src/callstack.cr")
    output.should_not contain("src/exception.cr")
    output.should_not contain("src/raise.cr")
  end

  it "doesn't relativize paths outside of current dir (#10169)", tags: %w[slow] do
    with_tempfile("source_file") do |source_file|
      source_path = Path.new(source_file)
      source_path.absolute?.should be_true

      File.write source_file, <<-CRYSTAL
        def callee1
          puts caller.join('\n')
        end

        callee1
        CRYSTAL
      _, output, _ = compile_and_run_file(source_file, CALL_STACK_SPEC_BUILD_FLAGS)

      output.should match /\A(#{Regex.escape(source_path.to_s)}):/
    end
  end

  it "prints exception backtrace to stderr", tags: %w[slow] do
    sample = datapath("exception_backtrace_sample")

    _, output, error = compile_and_run_file(sample)

    output.to_s.should be_empty
    error.to_s.should contain("IndexError")
  end

  {% if flag?(:openbsd) %}
    # FIXME: the segfault handler doesn't work on OpenBSD
    pending "prints crash backtrace to stderr"
  {% else %}
    it "prints crash backtrace to stderr", tags: %w[slow] do
      sample = datapath("crash_backtrace_sample")

      _, output, error = compile_and_run_file(sample)

      output.to_s.should be_empty
      error.to_s.should contain("Invalid memory access")
    end
  {% end %}

  # A method a type inherits is named `*Owner@Ancestor#method...`. ELF
  # symbol names carry `~at~` for that `@` (see `Crystal.safe_mangling`); a
  # backtrace without debug info reads the name from the dynamic symbol table
  # and still prints it with `@`.
  it "names an inherited method with its owner in a backtrace without debug info", tags: %w[slow] do
    _, output, _ = compile_and_run_source(<<-CRYSTAL, %w(--no-debug))
      abstract class InheritedBase
        def fail_here(value : Int32) : Int32
          raise "boom" if value > 0
          value
        end
      end

      class InheritedChild < InheritedBase
      end

      begin
        InheritedChild.new.fail_here(1)
      rescue ex
        puts ex.backtrace.join('\n')
      end
      CRYSTAL

    output.should contain("InheritedChild@InheritedBase#fail_here<Int32>:Int32")
    output.should_not contain("~at~")
  end

  {% unless flag?(:openbsd) %}
    it "names an inherited method with its owner in a crash backtrace without debug info", tags: %w[slow] do
      _, _, error = compile_and_run_source(<<-CRYSTAL, %w(--no-debug))
        abstract class CrashBase
          # The faulting function itself is not in the trace that the
          # signal handler walks; its caller is.
          def crash_here(value : Int32) : Int32
            read_at(value) &+ 1
          end

          def read_at(value : Int32) : Int32
            Pointer(Int32).new(value.to_u64).value
          end
        end

        class CrashChild < CrashBase
        end

        CrashChild.new.crash_here(0)
        CRYSTAL

      error.should contain("Invalid memory access")
      error.should contain("CrashChild@CrashBase#crash_here<Int32>:Int32")
      error.should_not contain("~at~")
    end
  {% end %}

  # Do not test this on platforms that cannot remove the current working
  # directory of the process:
  #
  # Solaris: https://man.freebsd.org/cgi/man.cgi?query=rmdir&sektion=2&manpath=SunOS+5.10
  # Windows: https://docs.microsoft.com/en-us/cpp/c-runtime-library/reference/rmdir-wrmdir?view=msvc-170#remarks
  {% unless flag?(:win32) || flag?(:solaris) %}
    it "print exception with non-existing PWD", tags: %w[slow] do
      source_file = datapath("blank_test_file.txt")
      compile_file(source_file) do |executable_file|
        output, error = IO::Memory.new, IO::Memory.new
        with_tempdir("non-existent") do
          Dir.delete(Dir.current)
          status = Process.run executable_file

          status.success?.should be_true
        end
      end
    end
  {% end %}
end
