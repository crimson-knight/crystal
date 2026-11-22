#include <llvm/Config/llvm-config.h>
#include <llvm/ADT/DenseMap.h>
#include <llvm/ADT/STLExtras.h>
#include <llvm/ADT/StringExtras.h>
#include <llvm/Bitcode/BitcodeWriter.h>
#include <llvm/IR/Module.h>
#include <llvm/IR/IRBuilder.h>
#include <llvm/MC/MCAsmInfo.h>
#include <llvm/Support/CodeGen.h>
#include <llvm/Support/CommandLine.h>
#include <llvm/Support/MemoryBuffer.h>
#include <llvm/Support/raw_ostream.h>
#include <llvm/Target/TargetMachine.h>
#include <llvm/Transforms/Utils/Cloning.h>
#if LLVM_VERSION_MAJOR >= 17
#include <llvm/TargetParser/Triple.h>
#else
#include <llvm/ADT/Triple.h>
#endif
#include <llvm-c/TargetMachine.h>

using namespace llvm;

#define LLVM_VERSION_GE(major, minor) \
  (LLVM_VERSION_MAJOR > (major) || LLVM_VERSION_MAJOR == (major) && LLVM_VERSION_MINOR >= (minor))

#if !LLVM_VERSION_GE(9, 0)
#include <llvm/IR/DIBuilder.h>
#endif

#if LLVM_VERSION_GE(16, 0)
#define makeArrayRef ArrayRef
#endif

#if !LLVM_VERSION_GE(18, 0)
typedef struct LLVMOpaqueOperandBundle *LLVMOperandBundleRef;
DEFINE_SIMPLE_CONVERSION_FUNCTIONS(OperandBundleDef, LLVMOperandBundleRef)
#endif

namespace {

void LLVMExtSetCommandLineOptionIfPresent(const char *name,
                                          const char *value = nullptr) {
  auto &options = cl::getRegisteredOptions();
  auto it = options.find(name);
  if (it == options.end())
    return;

  auto *option = it->second;
  StringRef arg_name = option->ArgStr;
  StringRef arg_value = value ? StringRef(value) : StringRef();
  (void)option->addOccurrence(0, arg_name, arg_value);
}

void LLVMExtEnableLegacyWasmExceptionHandlingOptions() {
  LLVMExtSetCommandLineOptionIfPresent("wasm-enable-eh");

  auto &options = cl::getRegisteredOptions();
  if (options.find("wasm-use-legacy-eh") != options.end()) {
    LLVMExtSetCommandLineOptionIfPresent("wasm-use-legacy-eh");
  } else if (options.find("wasm-enable-exnref") != options.end()) {
    LLVMExtSetCommandLineOptionIfPresent("wasm-enable-exnref", "false");
  }
}

} // namespace

extern "C" {

#if !LLVM_VERSION_GE(9, 0)
LLVMMetadataRef LLVMExtDIBuilderCreateEnumerator(LLVMDIBuilderRef Builder,
                                                 const char *Name, size_t NameLen,
                                                 int64_t Value,
                                                 LLVMBool IsUnsigned) {
  return wrap(unwrap(Builder)->createEnumerator({Name, NameLen}, Value,
                                                IsUnsigned != 0));
}

void LLVMExtClearCurrentDebugLocation(LLVMBuilderRef B) {
  unwrap(B)->SetCurrentDebugLocation(DebugLoc::get(0, 0, nullptr));
}
#endif

#if !LLVM_VERSION_GE(18, 0)
LLVMOperandBundleRef LLVMExtCreateOperandBundle(const char *Tag, size_t TagLen,
                                                LLVMValueRef *Args,
                                                unsigned NumArgs) {
  return wrap(new OperandBundleDef(std::string(Tag, TagLen),
                                   makeArrayRef(unwrap(Args), NumArgs)));
}

void LLVMExtDisposeOperandBundle(LLVMOperandBundleRef Bundle) {
  delete unwrap(Bundle);
}

LLVMValueRef
LLVMExtBuildCallWithOperandBundles(LLVMBuilderRef B, LLVMTypeRef Ty,
                                   LLVMValueRef Fn, LLVMValueRef *Args,
                                   unsigned NumArgs, LLVMOperandBundleRef *Bundles,
                                   unsigned NumBundles, const char *Name) {
  FunctionType *FTy = unwrap<FunctionType>(Ty);
  SmallVector<OperandBundleDef, 8> OBs;
  for (auto *Bundle : makeArrayRef(Bundles, NumBundles)) {
    OperandBundleDef *OB = unwrap(Bundle);
    OBs.push_back(*OB);
  }
  return wrap(unwrap(B)->CreateCall(
      FTy, unwrap(Fn), makeArrayRef(unwrap(Args), NumArgs), OBs, Name));
}

LLVMValueRef LLVMExtBuildInvokeWithOperandBundles(
    LLVMBuilderRef B, LLVMTypeRef Ty, LLVMValueRef Fn, LLVMValueRef *Args,
    unsigned NumArgs, LLVMBasicBlockRef Then, LLVMBasicBlockRef Catch,
    LLVMOperandBundleRef *Bundles, unsigned NumBundles, const char *Name) {
  SmallVector<OperandBundleDef, 8> OBs;
  for (auto *Bundle : makeArrayRef(Bundles, NumBundles)) {
    OperandBundleDef *OB = unwrap(Bundle);
    OBs.push_back(*OB);
  }
  return wrap(unwrap(B)->CreateInvoke(
      unwrap<FunctionType>(Ty), unwrap(Fn), unwrap(Then), unwrap(Catch),
      makeArrayRef(unwrap(Args), NumArgs), OBs, Name));
}
#endif

#if !LLVM_VERSION_GE(18, 0)
static TargetMachine *unwrap(LLVMTargetMachineRef P) {
  return reinterpret_cast<TargetMachine *>(P);
}

void LLVMExtSetTargetMachineGlobalISel(LLVMTargetMachineRef T, LLVMBool Enable) {
  unwrap(T)->setGlobalISel(Enable);
}
#endif

// Enable WASM exception handling on a target machine.
//
// On LLVM < 22, this function does four things:
// 1. Sets TargetOptions.ExceptionModel to Wasm (used by the new pass manager
//    and by getExceptionModel())
// 2. Sets MCAsmInfo.ExceptionsType to Wasm (used by the MC layer to emit
//    exception tables). The LLVM C API constructor fails to propagate this.
// 3. Enables the WebAssembly backend EH flags through LLVM's registered
//    command-line option table. This avoids directly linking against backend
//    globals that are not exported by some shared LLVM packages.
// 4. Prefers legacy try/catch emission when the backend exposes a switch for
//    that mode.
//
// On LLVM 23+, steps 1-2 are handled by LLVMTargetMachineOptionsSetExceptionModel
// in the C API, so this function only sets the cl::opt flags (steps 3-4).
//
// We use legacy EH (try/catch) instead of new EH (try_table/exnref) because
// Binaryen's Asyncify pass does not support the new try_table instructions.
// After Asyncify, we run --translate-to-exnref to convert to the new format.
void LLVMExtSetWasmExceptionHandling(LLVMTargetMachineRef T) {
#if !LLVM_VERSION_GE(23, 0)
  // Pre-LLVM 23: Must set ExceptionModel manually since the C API doesn't
  // expose LLVMTargetMachineOptionsSetExceptionModel.
  auto *TM = reinterpret_cast<TargetMachine *>(T);
  TM->Options.ExceptionModel = ExceptionHandling::Wasm;
  const_cast<MCAsmInfo *>(TM->getMCAsmInfo())
      ->setExceptionsType(ExceptionHandling::Wasm);
#endif
  LLVMExtEnableLegacyWasmExceptionHandlingOptions();
}

// Moves the function declarations (functions without a body) of a module to
// its end, ordered by name. Definitions keep their order, and no use of a
// function changes. The bitcode of a module then does not depend on the
// order its declarations were made in.
void LLVMExtSortFunctionDeclarationsByName(LLVMModuleRef M) {
  Module &module = *unwrap(M);
  std::vector<Function *> declarations;
  for (Function &function : module)
    if (function.isDeclaration())
      declarations.push_back(&function);
  llvm::sort(declarations, [](Function *a, Function *b) {
    return a->getName() < b->getName();
  });
  auto &functions = module.getFunctionList();
  for (Function *function : declarations)
    functions.splice(functions.end(), functions, function->getIterator());
}

// Whether `LLVMExtSplitModuleToBitcode` can split this module: it needs
// LLVM 17 or later, and a module without module-level assembly, which
// SplitModule cannot keep consistent across parts.
LLVMBool LLVMExtModuleCanBeSplit(LLVMModuleRef M) {
#if LLVM_VERSION_MAJOR >= 17
  return unwrap(M)->getModuleInlineAsm().empty();
#else
  return false;
#endif
}

// Split a module into `parts` modules and hand each one to `callback` as
// bitcode, in partition order, as soon as it is written.
//
// Each part holds a contiguous run of the module's functions (and of its global
// variables), cut so the parts have about the same number of instructions.
// The linker lays the part objects out one after another, so the executable
// keeps the single-object build's order of functions, and code that runs
// together stays on the same memory pages. (LLVM's SplitModule deals functions
// out round-robin, which spreads a request's hot path over every part: a small
// Amber server touched about 0.4 MiB more of its executable.)
//
// The module is changed in place. Every local definition becomes an external
// symbol with hidden visibility, as SplitModule does, so references across
// parts resolve when the objects are linked. Before that, each local definition whose name
// could meet another object's symbol in the link is renamed:
//
// - private definitions (string literals, constant tables) and internal
//   global variables get the prefix `__crystal_private.`. A single-object
//   build lists none of the private ones in the executable's symbol table and
//   merges most of the variables into one symbol, so these names are kept out
//   of the executable: on Mach-O the name also starts with `l`, which Apple's
//   linker resolves across objects and leaves out of the output's symbol
//   table and debug map (the compiler also passes them to the linker as a
//   strip list, for ld64.lld); on ELF the compiler removes them after
//   linking;
// - internal functions whose names are plain C identifiers get the prefix
//   `__crystal_local.`;
// - internal functions whose names hold a character that no C, C++,
//   Objective-C, Rust or Swift global symbol uses (Crystal method names such
//   as `*Foo#bar:Int32`) keep their names, so the executable lists the same
//   functions under the same names as a single-object build.
//
// No C or Crystal external symbol uses either prefix, so a promoted name
// cannot collide with a symbol of another object in the link. Each part is
// serialized because LLVM contexts are not thread-safe: the receiver parses
// it into a context of its own and compiles it on any thread (LLVM's LTO
// `splitCodeGen` does the same). The callback owns the buffer it receives and
// must dispose of it; it must not unwind (it is called from C++).
//
// Returns the number of parts handed to `callback` (always `parts`), or 0
// without changing the module when `LLVMExtModuleCanBeSplit` is false for it.
unsigned LLVMExtSplitModuleToBitcode(LLVMModuleRef M, unsigned parts,
                                     void (*callback)(void *data, unsigned index,
                                                      LLVMMemoryBufferRef buffer),
                                     void *data) {
  if (!LLVMExtModuleCanBeSplit(M))
    return 0;
#if LLVM_VERSION_MAJOR >= 17
  Module &module = *unwrap(M);

  auto is_plain_symbol_character = [](char character) {
    return isAlnum(character) || character == '_' || character == '.' ||
           character == '$';
  };
  // A leading \1 asks the mangler to keep the name as written, without the
  // `_` global prefix Mach-O adds, so the promoted name starts with `l`.
  bool is_mach_o = Triple(module.getTargetTriple()).isOSBinFormatMachO();
  StringRef private_prefix = is_mach_o ? "\1l__crystal_private." : "__crystal_private.";

  auto rename_local = [&](GlobalValue &value) {
    if (value.isDeclaration() || !value.hasLocalLinkage())
      return;
    // A promoted name is used by these parts alone, so it is mangled as usual
    // (apart from the Mach-O prefix above) even if the local's name asked
    // the mangler to keep it as written.
    StringRef name = value.getName();
    if (name.starts_with("\1"))
      name = name.drop_front(1);
    if (value.hasPrivateLinkage() || isa<GlobalVariable>(value)) {
      value.setName(private_prefix + (name.empty() ? StringRef("unnamed") : name));
      return;
    }
    bool keeps_its_name = !name.empty() && !name.starts_with("__crystal_") &&
                          !llvm::all_of(name, is_plain_symbol_character);
    if (keeps_its_name)
      return;
    value.setName(Twine("__crystal_local.") + (name.empty() ? StringRef("unnamed") : name));
  };
  for (Function &function : module)
    rename_local(function);
  for (GlobalVariable &variable : module.globals())
    rename_local(variable);
  for (GlobalAlias &alias : module.aliases())
    rename_local(alias);
  for (GlobalIFunc &ifunc : module.ifuncs())
    rename_local(ifunc);

// Make every local definition external and hidden, and name the unnamed
// ones, so each part can refer to what another part defines.
auto externalize = [](GlobalValue &value) {
  if (value.hasLocalLinkage()) {
    value.setLinkage(GlobalValue::ExternalLinkage);
    value.setVisibility(GlobalValue::HiddenVisibility);
  }
  if (!value.hasName())
    value.setName("__llvmsplit_unnamed");
};
for (Function &function : module)
  externalize(function);
for (GlobalVariable &variable : module.globals())
  externalize(variable);
for (GlobalAlias &alias : module.aliases())
  externalize(alias);
for (GlobalIFunc &ifunc : module.ifuncs())
  externalize(ifunc);

// Assign each definition its part. Functions and global variables are cut
// into contiguous runs in module order; members of a comdat stay with the
// first member; an alias or ifunc goes with the object it names.
DenseMap<const GlobalValue *, unsigned> part_of_value;
DenseMap<const Comdat *, unsigned> part_of_comdat;
auto assign = [&](const GlobalObject &object, unsigned part) {
  if (const Comdat *comdat = object.getComdat()) {
    auto [entry, inserted] = part_of_comdat.try_emplace(comdat, part);
    part = entry->second;
  }
  part_of_value[&object] = part;
};

uint64_t total_instructions = 0;
for (const Function &function : module)
  if (!function.isDeclaration())
    total_instructions += std::max(function.getInstructionCount(), 1u);
uint64_t instructions_before = 0;
for (const Function &function : module) {
  if (function.isDeclaration())
    continue;
  assign(function, std::min<uint64_t>(instructions_before * parts / total_instructions, parts - 1));
  instructions_before += std::max(function.getInstructionCount(), 1u);
}

uint64_t total_variables = 0;
for (const GlobalVariable &variable : module.globals())
  if (!variable.isDeclaration())
    total_variables += 1;
uint64_t variables_before = 0;
for (const GlobalVariable &variable : module.globals()) {
  if (variable.isDeclaration())
    continue;
  assign(variable, std::min<uint64_t>(variables_before * parts / total_variables, parts - 1));
  variables_before += 1;
}

auto part_of = [&](const GlobalValue *value) -> unsigned {
  if (auto *alias = dyn_cast<GlobalAlias>(value))
    if (const GlobalObject *object = alias->getAliaseeObject())
      value = object;
  if (auto *ifunc = dyn_cast<GlobalIFunc>(value))
    if (const GlobalObject *object = ifunc->getResolverFunction())
      value = object;
  auto entry = part_of_value.find(value);
  return entry == part_of_value.end() ? 0 : entry->second;
};

unsigned index = 0;
for (unsigned part_index = 0; part_index < parts; ++part_index) {
  ValueToValueMapTy value_map;
  std::unique_ptr<Module> part = CloneModule(module, value_map, [&](const GlobalValue *value) {
    return part_of(value) == part_index;
  });
  SmallString<0> bitcode;
  raw_svector_ostream stream(bitcode);
  WriteBitcodeToFile(*part, stream);
  part.reset();
  auto buffer = MemoryBuffer::getMemBufferCopy(
      StringRef(bitcode.data(), bitcode.size()), "crystal-release-part");
  callback(data, index++, wrap(buffer.release()));
}
  return index;
#else
  return 0;
#endif
}

} // extern "C"
