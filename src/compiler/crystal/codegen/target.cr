require "llvm"
require "../error"

class Crystal::Codegen::Target
  class Error < Crystal::Error
  end

  @@wasm_eh_initialized = false

  getter architecture : String
  getter vendor : String
  getter environment : String

  def initialize(target_triple : String)
    # Let LLVM convert the user-inputted target triple into at least a target
    # triple with the architecture, vendor and OS in the correct place.
    target_triple = LLVM.normalize_triple(target_triple.downcase)

    if target_triple.count('-') < 2
      raise Target::Error.new("Invalid target triple: #{target_triple}")
    end
    @architecture, @vendor, @environment = target_triple.split('-', 3)

    # Perform additional normalization and parsing
    case @architecture
    when "i486", "i586", "i686"
      @architecture = "i386"
    when "amd64"
      @architecture = "x86_64"
    when "arm64"
      @architecture = "aarch64"
    when .starts_with?("arm")
      @architecture = "arm"
    else
      # no need to tweak the architecture
    end

    # Normalize WASI Preview 1 target name: "wasip1" -> "wasi"
    # Rust removed wasm32-wasi in January 2025, replacing it with
    # wasm32-wasip1 to be explicit about WASI Preview 1. We accept
    # both names and normalize to "wasi" for the LLVM target triple.
    if @environment == "wasip1"
      @environment = "wasi"
    end

    if linux? && environment_parts.size == 1
      case @vendor
      when "suse", "redhat", "slackware", "amazon", "unknown", "montavista", "mti"
        # Build string instead of setting it as "linux-gnu"
        # since "linux6E" & "linuxspe" are available.
        @environment = "#{@environment}-gnu"
      else
        # no need to tweak the environment
      end
    end
  end

  def environment_parts
    @environment.split('-')
  end

  def pointer_bit_width
    case @architecture
    when "aarch64", "x86_64"
      64
    when "arm", "i386", "wasm32"
      32
    when "avr"
      16
    else
      raise "BUG: unknown Target#pointer_bit_width for #{@architecture} target architecture"
    end
  end

  def size_bit_width
    case @architecture
    when "aarch64", "x86_64"
      64
    when "arm", "i386", "wasm32"
      32
    when "avr"
      16
    else
      raise "BUG: unknown Target#size_bit_width for #{@architecture} target architecture"
    end
  end

  def os_name
    case self
    when .macos?
      "darwin"
    when .freebsd?
      "freebsd"
    when .dragonfly?
      "dragonfly"
    when .openbsd?
      "openbsd"
    when .netbsd?
      "netbsd"
    when .solaris?
      "solaris"
    when .android?
      "android"
    else
      environment
    end
  end

  def executable_extension
    case
    when windows? then ".exe"
    when avr?     then ".elf"
    else               ""
    end
  end

  def object_extension
    case
    when windows?                  then ".obj"
    when @architecture == "wasm32" then ".wasm"
    else                                ".o"
    end
  end

  def macos?
    @environment.starts_with?("darwin") || @environment.starts_with?("macos")
  end

  def freebsd?
    @environment.starts_with?("freebsd")
  end

  def freebsd_version
    if @environment =~ /freebsd(\d+)\.\d+/
      $1.to_i
    else
      nil
    end
  end

  def dragonfly?
    @environment.starts_with?("dragonfly")
  end

  def openbsd?
    @environment.starts_with?("openbsd")
  end

  def netbsd?
    @environment.starts_with?("netbsd")
  end

  def android?
    environment_parts.any? &.starts_with?("android")
  end

  def linux?
    @environment.starts_with?("linux")
  end

  def solaris?
    @environment.starts_with?("solaris")
  end

  def wasi?
    @environment.starts_with?("wasi")
  end

  def bsd?
    freebsd? || netbsd? || openbsd? || dragonfly?
  end

  def unix?
    macos? || bsd? || linux? || wasi? || solaris?
  end

  def gnu?
    environment_parts.any? &.in?("gnu", "gnueabi", "gnueabihf")
  end

  def musl?
    environment_parts.any? &.in?("musl", "musleabi", "musleabihf")
  end

  def windows?
    @environment.starts_with?("win32") || @environment.starts_with?("windows")
  end

  def msvc?
    windows? && environment_parts.includes?("msvc")
  end

  def win32?
    windows? && (msvc? || gnu?)
  end

  def armhf?
    environment_parts.any? &.in?("gnueabihf", "musleabihf")
  end

  def avr?
    @architecture == "avr"
  end

  def embedded?
    environment_parts.any? { |part| part == "eabi" || part == "eabihf" }
  end

  def to_target_machine(cpu = "", features = "", optimization_mode = Compiler::OptimizationMode::O0,
                        code_model = LLVM::CodeModel::Default) : LLVM::TargetMachine
    # Auto-detect host CPU when building for the same architecture and no
    # explicit CPU was requested. This allows LLVM to use native instruction
    # scheduling and feature detection for the host machine.
    if cpu.empty?
      host_triple = LLVM.default_target_triple
      host_arch = host_triple.split('-', 2).first
      # Normalize host architecture the same way we normalize @architecture
      host_arch = case host_arch
                  when "i486", "i586", "i686" then "i386"
                  when "amd64"                then "x86_64"
                  when "arm64"                then "aarch64"
                  else                             host_arch
                  end
      if host_arch == @architecture
        cpu = LLVM.host_cpu_name
      end
    end

    case @architecture
    when "i386", "x86_64"
      LLVM.init_x86
    when "aarch64"
      LLVM.init_aarch64
    when "arm"
      LLVM.init_arm

      # Enable most conservative FPU for hard-float capable targets, unless a
      # CPU is defined (it will most certainly enable a better FPU) or
      # features contains a floating-point definition.
      if cpu.empty? && !features.includes?("fp") && armhf?
        features += "+vfp2"
      end
    when "avr"
      LLVM.init_avr

      if cpu.blank?
        # the ABI call convention, codegen and the linker need to known the CPU model
        raise Target::Error.new("AVR targets must declare a CPU model, for example --mcpu=atmega328p")
      end
    when "wasm32"
      LLVM.init_webassembly
      features += "+exception-handling,+bulk-memory,+mutable-globals,+sign-ext,+nontrapping-fptoint,+multivalue,+reference-types"
      # Enable WASM exception handling in the LLVM backend.
      # -wasm-enable-eh: master switch for WASM exception handling
      # -wasm-use-legacy-eh=true: emit legacy try/catch format (not new try_table/exnref)
      #   We use legacy EH because Binaryen's Asyncify pass (needed for fiber
      #   context switching) does not support the new try_table instructions.
      #   After Asyncify, we run --translate-to-exnref to convert to the new format.
      # -exception-model=wasm: sets the exception handling model
      # We use @@wasm_eh_initialized to ensure this is only called once.
      unless @@wasm_eh_initialized
        @@wasm_eh_initialized = true
        LLVM.parse_command_line_options({"", "-wasm-enable-eh", "-wasm-use-legacy-eh=true", "-exception-model=wasm"})
      end
    else
      raise Target::Error.new("Unsupported architecture for target triple: #{self}")
    end

    opt_level = case optimization_mode
                in .o3?             then LLVM::CodeGenOptLevel::Aggressive
                in .o2?, .os?, .oz? then LLVM::CodeGenOptLevel::Default
                in .o1?             then LLVM::CodeGenOptLevel::Less
                in .o0?             then LLVM::CodeGenOptLevel::None
                end

    if embedded?
      reloc = LLVM::RelocMode::Static
    else
      reloc = LLVM::RelocMode::PIC
    end

    target = LLVM::Target.from_triple(self.to_s)

    machine = {% unless LibLLVM::IS_LT_220 %}
      # LLVM 22+: Use TargetMachineOptions API which properly sets
      # ExceptionModel before target machine construction.
      begin
        options = LibLLVM.create_target_machine_options
        LibLLVM.target_machine_options_set_cpu(options, cpu)
        LibLLVM.target_machine_options_set_features(options, features)
        LibLLVM.target_machine_options_set_code_gen_opt_level(options, opt_level)
        LibLLVM.target_machine_options_set_reloc_mode(options, reloc)
        LibLLVM.target_machine_options_set_code_model(options, code_model)
        if @architecture == "wasm32"
          LibLLVM.target_machine_options_set_exception_model(options, LLVM::ExceptionModel::Wasm)
        end
        m = LLVM::TargetMachine.new(LibLLVM.create_target_machine_with_options(target.to_unsafe, self.to_s, options))
        LibLLVM.dispose_target_machine_options(options)
        m
      end
    {% else %}
      target.create_target_machine(self.to_s, cpu: cpu, features: features, opt_level: opt_level, reloc: reloc, code_model: code_model).not_nil!
    {% end %}

    # FIXME: We need to disable global isel until https://reviews.llvm.org/D80898 is released,
    # or we fixed generating values for 0 sized types.
    # When removing this, also remove it from the ABI specs and jit compiler.
    # See https://github.com/crystal-lang/crystal/issues/9297#issuecomment-636512270
    # for background info
    machine.enable_global_isel = false

    # For WASM targets, enable WASM exception handling on the target machine.
    # On LLVM 22+, ExceptionModel is already set via TargetMachineOptions above,
    # but we still need the C++ helper to set cl::opt flags (WasmEnableEH,
    # WasmUseLegacyEH) and, on older LLVM, to set TargetOptions.ExceptionModel
    # and fix MCAsmInfo.ExceptionsType.
    if @architecture == "wasm32"
      machine.enable_wasm_eh
    end

    machine
  end

  def to_s(io : IO) : Nil
    io << architecture << '-' << vendor << '-' << environment
  end

  def ==(other : self)
    return false unless architecture == other.architecture

    # If any vendor is unknown, we can skip it. But if both are known, they must
    # match.
    if vendor != "unknown" && other.vendor != "unknown"
      return false unless vendor == other.vendor
    end

    environment == other.environment
  end
end
