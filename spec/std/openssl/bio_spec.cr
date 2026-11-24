require "../spec_helper"
require "openssl"

describe OpenSSL::BIO do
  describe ".crystal_bio" do
    it "builds the Crystal BIO method table once and reuses it" do
      first = OpenSSL::BIO.crystal_bio
      first.null?.should be_false
      OpenSSL::BIO.crystal_bio_initialized?.should be_true
      OpenSSL::BIO.crystal_bio.should eq(first)
    end

    it "calls no OpenSSL function at program start when TLS is reachable but unused" do
      status, output, error = compile_and_run_source(<<-CRYSTAL, runtime_args: %w(plain))
      require "openssl"

      puts OpenSSL::BIO.crystal_bio_initialized?
      if ARGV.first? == "tls"
        OpenSSL::BIO.new(IO::Memory.new)
      end
      puts OpenSSL::BIO.crystal_bio_initialized?
      CRYSTAL

      error.should eq("")
      status.success?.should be_true
      output.should eq("false\nfalse\n")
    end

    it "builds the method table on first use after start-up" do
      status, output, error = compile_and_run_source(<<-CRYSTAL, runtime_args: %w(tls))
      require "openssl"

      puts OpenSSL::BIO.crystal_bio_initialized?
      if ARGV.first? == "tls"
        OpenSSL::BIO.new(IO::Memory.new)
      end
      puts OpenSSL::BIO.crystal_bio_initialized?
      CRYSTAL

      error.should eq("")
      status.success?.should be_true
      output.should eq("false\ntrue\n")
    end

    it "gives every thread the same method table when they race for the first use" do
      status, output, error = compile_and_run_source(<<-CRYSTAL, flags: %w(-Dpreview_mt))
      require "openssl"

      thread_count = 8
      ready = Atomic(Int32).new(0)
      list_of_tables = Array(Pointer(LibCrypto::BioMethod)).new(thread_count, Pointer(LibCrypto::BioMethod).null)
      list_of_threads = Array.new(thread_count) do |index|
        Thread.new do
          ready.add(1)
          until ready.get == thread_count
          end
          list_of_tables[index] = OpenSSL::BIO.crystal_bio
          OpenSSL::BIO.new(IO::Memory.new)
        end
      end
      list_of_threads.each(&.join)
      puts list_of_tables.uniq.size
      puts list_of_tables.first.null?
      CRYSTAL

      error.should eq("")
      status.success?.should be_true
      output.should eq("1\nfalse\n")
    end
  end
end
