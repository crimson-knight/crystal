require "./codegen_worker"

module Crystal
  # Builds object files from bitcode files in `CodegenWorker` processes.
  #
  # A worker's memory grows with the bitcode of the module it compiles, so
  # the pool keeps the estimated memory of the jobs in flight within a
  # budget. The largest job that fits goes out first; a job larger than the
  # whole budget runs when nothing else is in flight. A worker process is
  # started the first time a job is handed to it, so a tight budget also
  # starts fewer processes.
  class CodegenWorkerPool
    # Memory a worker needs per byte of bitcode it compiles, and the memory
    # a worker holds before it loads a module. Measured at `-O3` on the 12
    # largest modules of a 300-model Grant app (4 to 59 MB of bitcode), each
    # compiled alone: peak footprint was 30 to 110 times the bitcode size
    # with no trend by size, and 8 to 28 MB for modules under 0.4 MB. The
    # factor is the largest ratio seen, so an estimate is an upper bound.
    MEMORY_BYTES_PER_BITCODE_BYTE = 110_i64
    WORKER_BASE_MEMORY_BYTES      = 16_i64 * 1024 * 1024

    # The memory each allowed thread adds to the default budget, and the
    # share of the machine's memory the default budget stops at.
    DEFAULT_MEMORY_BYTES_PER_THREAD = 1280_i64 * 1024 * 1024
    DEFAULT_PHYSICAL_MEMORY_DIVISOR = 3

    # How many worker processes were started.
    getter worker_count = 0

    # The largest estimated memory of the jobs that were in flight together.
    getter maximum_in_flight_memory_bytes = 0_i64

    # The largest bitcode size of the jobs that were in flight together.
    getter maximum_in_flight_bitcode_bytes = 0_i64

    getter memory_budget_bytes : Int64

    # The default budget: 1.25 GiB per allowed thread, at most a third of the
    # machine's memory.
    def self.default_memory_budget_bytes(thread_count : Int32) : Int64
      budget = thread_count.to_i64 * DEFAULT_MEMORY_BYTES_PER_THREAD
      if physical_memory_bytes = self.physical_memory_bytes
        budget = Math.min(budget, physical_memory_bytes // DEFAULT_PHYSICAL_MEMORY_DIVISOR)
      end
      budget
    end

    # The memory installed in this machine, when the system tells.
    def self.physical_memory_bytes : Int64?
      {% if flag?(:darwin) %}
        memory_bytes = 0_u64
        bytesize = LibC::SizeT.new(sizeof(UInt64))
        if LibDarwinSysctl.sysctlbyname("hw.memsize", pointerof(memory_bytes), pointerof(bytesize), nil, 0) == 0
          memory_bytes.to_i64
        end
      {% elsif flag?(:linux) %}
        File.each_line("/proc/meminfo") do |line|
          if kibibytes = line.lchop?("MemTotal:")
            return kibibytes.strip.rchop("kB").strip.to_i64 * 1024
          end
        end
        nil
      {% else %}
        nil
      {% end %}
    rescue IO::Error | ArgumentError
      nil
    end

    {% if flag?(:darwin) %}
      lib LibDarwinSysctl
        fun sysctlbyname(name : LibC::Char*, oldp : Void*, oldlenp : LibC::SizeT*, newp : Void*, newlen : LibC::SizeT) : LibC::Int
      end
    {% end %}

    # The memory a worker is expected to need while it compiles *job*.
    def self.estimated_memory_bytes(job : CodegenWorker::Job) : Int64
      WORKER_BASE_MEMORY_BYTES + job.bitcode_bytesize * MEMORY_BYTES_PER_BITCODE_BYTE
    end

    @list_of_jobs : Array(CodegenWorker::Job)
    @list_of_memory_estimates : Array(Int64)

    def initialize(@worker_executable : String, @settings : CodegenWorker::Settings,
                   list_of_jobs : Array(CodegenWorker::Job), @thread_count : Int32,
                   @memory_budget_bytes : Int64)
      @list_of_jobs = list_of_jobs.sort_by { |job| -job.bitcode_bytesize }
      @list_of_memory_estimates = @list_of_jobs.map { |job| self.class.estimated_memory_bytes(job) }
      @job_was_handed_out = Array(Bool).new(@list_of_jobs.size, false)
      @first_waiting_job_index = 0
      @in_flight_memory_bytes = 0_i64
      @in_flight_bitcode_bytes = 0_i64
    end

    # Builds every job's object file, yielding after each one. Raises
    # `CompilerError` when a worker fails; the jobs under way then finish and
    # no further job starts.
    def perform(& : ->) : Nil
      return if @list_of_jobs.empty?

      settings_line = @settings.to_json
      seat_count = @thread_count.clamp(1..@list_of_jobs.size)
      list_of_seats = Array.new(seat_count) { Seat.new(@worker_executable, settings_line) }
      list_of_idle_seats = list_of_seats.reverse
      finished_jobs = Channel(FinishedJob).new(seat_count)
      jobs_in_flight = 0
      first_failure_message = nil.as(String?)

      loop do
        while first_failure_message.nil? && !list_of_idle_seats.empty? && (job_index = next_job_index)
          seat = list_of_idle_seats.pop
          @worker_count += 1 unless seat.started?
          hand_out(job_index)
          jobs_in_flight += 1
          run_job(seat, job_index, finished_jobs)
        end
        break if jobs_in_flight == 0

        finished_job = finished_jobs.receive
        jobs_in_flight -= 1
        @in_flight_memory_bytes -= @list_of_memory_estimates[finished_job.job_index]
        @in_flight_bitcode_bytes -= @list_of_jobs[finished_job.job_index].bitcode_bytesize
        if failure_message = finished_job.failure_message
          first_failure_message ||= failure_message
        else
          list_of_idle_seats << finished_job.seat
          yield
        end
      end

      list_of_seats.each do |seat|
        if failure_message = seat.close
          first_failure_message ||= failure_message
        end
      end

      if first_failure_message
        raise CompilerError.new("object file worker failed: #{first_failure_message}")
      end
    end

    private record FinishedJob, seat : Seat, job_index : Int32, failure_message : String?

    private def run_job(seat : Seat, job_index : Int32, finished_jobs : Channel(FinishedJob)) : Nil
      job = @list_of_jobs[job_index]
      spawn do
        failure_message = begin
          seat.compile(job)
        rescue ex
          "#{ex.message} (#{ex.class})"
        end
        finished_jobs.send FinishedJob.new(seat, job_index, failure_message)
      end
    end

    private def hand_out(job_index : Int32) : Nil
      @job_was_handed_out[job_index] = true
      @in_flight_memory_bytes += @list_of_memory_estimates[job_index]
      @in_flight_bitcode_bytes += @list_of_jobs[job_index].bitcode_bytesize
      @maximum_in_flight_memory_bytes = Math.max(@maximum_in_flight_memory_bytes, @in_flight_memory_bytes)
      @maximum_in_flight_bitcode_bytes = Math.max(@maximum_in_flight_bitcode_bytes, @in_flight_bitcode_bytes)
    end

    # The largest waiting job that fits in what is left of the budget, or the
    # largest waiting job when nothing is in flight.
    private def next_job_index : Int32?
      while @first_waiting_job_index < @list_of_jobs.size && @job_was_handed_out[@first_waiting_job_index]
        @first_waiting_job_index += 1
      end
      return nil if @first_waiting_job_index == @list_of_jobs.size
      return @first_waiting_job_index if @in_flight_memory_bytes == 0

      room = @memory_budget_bytes - @in_flight_memory_bytes
      (@first_waiting_job_index...@list_of_jobs.size).find do |job_index|
        !@job_was_handed_out[job_index] && @list_of_memory_estimates[job_index] <= room
      end
    end

    # One place among the allowed threads: a worker process that is started
    # with its first job and compiles one job at a time.
    private class Seat
      @process : Process?

      def initialize(@worker_executable : String, @settings_line : String)
      end

      def started? : Bool
        !@process.nil?
      end

      # Has the worker compile *job*. Returns what went wrong, or `nil` when
      # the object file was written.
      def compile(job : CodegenWorker::Job) : String?
        process = @process ||= start
        process.input.puts job.to_json
        process.input.flush
        outcome_line = process.output.gets
        return "the worker stopped while compiling #{job.name}" unless outcome_line

        CodegenWorker::Outcome.from_json(outcome_line).error_message
      rescue ex : IO::Error
        "lost the connection to the worker (#{ex.message})"
      end

      # Ends the worker. Returns what went wrong when it exited abnormally
      # after answering all its jobs.
      def close : String?
        process = @process
        return nil unless process

        begin
          process.input.close
        rescue IO::Error
          # the worker is already gone; its exit status tells
        end
        status = process.wait
        status.success? ? nil : "the worker exited abnormally (#{status})"
      end

      private def start : Process
        process = Process.new(@worker_executable, [CodegenWorker::COMMAND],
          input: :pipe, output: :pipe, error: :inherit)
        process.input.puts @settings_line
        process
      end
    end
  end
end
