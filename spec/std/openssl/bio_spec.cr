require "../spec_helper"
require "openssl"

# A program that uses the Crystal BIO method table from fibers racing on several
# threads. `SPAWN` is replaced by the call that starts each fiber.
private RACE_PROGRAM = <<-CRYSTAL
  require "openssl"
  require "wait_group"

  fiber_count = 8
  ready = Atomic(Int32).new(0)
  list_of_tables = Array(Pointer(LibCrypto::BioMethod)).new(fiber_count, Pointer(LibCrypto::BioMethod).null)
  wait_group = WaitGroup.new(fiber_count)
  fiber_count.times do |index|
    SPAWN do
      ready.add(1)
      until ready.get == fiber_count
        Fiber.yield
      end
      list_of_tables[index] = OpenSSL::BIO.crystal_bio
      OpenSSL::BIO.new(IO::Memory.new)
    ensure
      wait_group.done
    end
  end
  wait_group.wait
  puts list_of_tables.uniq.size
  puts list_of_tables.first.null?
  CRYSTAL

# Reports whether the method table exists at start and after the program's TLS
# code may have run (it runs only when the first argument is "tls").
private FIRST_USE_PROGRAM = <<-CRYSTAL
  require "openssl"

  puts OpenSSL::BIO.crystal_bio_initialized?
  if ARGV.first? == "tls"
    OpenSSL::BIO.new(IO::Memory.new)
  end
  puts OpenSSL::BIO.crystal_bio_initialized?
  CRYSTAL

describe OpenSSL::BIO do
  describe ".crystal_bio" do
    it "builds the Crystal BIO method table once and reuses it" do
      first = OpenSSL::BIO.crystal_bio
      first.null?.should be_false
      OpenSSL::BIO.crystal_bio_initialized?.should be_true
      OpenSSL::BIO.crystal_bio.should eq(first)
    end

    it "calls no OpenSSL function at program start when TLS is reachable but unused" do
      status, output, error = compile_and_run_source(FIRST_USE_PROGRAM, runtime_args: %w(plain))

      error.should eq("")
      status.success?.should be_true
      output.should eq("false\nfalse\n")
    end

    it "builds the method table on first use after start-up" do
      status, output, error = compile_and_run_source(FIRST_USE_PROGRAM, runtime_args: %w(tls))

      error.should eq("")
      status.success?.should be_true
      output.should eq("false\ntrue\n")
    end

    # The racers are fibers: a bare `Thread` that waits in `Crystal.once` is never
    # woken, which holds for constants and class variables on the base stdlib too.
    it "gives every fiber the same method table when they race on -Dpreview_mt threads" do
      source = RACE_PROGRAM.sub("SPAWN", "spawn")
      status, output, error = compile_and_run_source(source, flags: %w(-Dpreview_mt))

      error.should eq("")
      status.success?.should be_true
      output.should eq("1\nfalse\n")
    end

    it "gives every fiber the same method table when they race in a parallel execution context" do
      source = %(context = Fiber::ExecutionContext::Parallel.new("bio-race", 4)\n) +
               RACE_PROGRAM.sub("SPAWN", "context.spawn")
      status, output, error = compile_and_run_source(source)

      error.should eq("")
      status.success?.should be_true
      output.should eq("1\nfalse\n")
    end
  end
end
