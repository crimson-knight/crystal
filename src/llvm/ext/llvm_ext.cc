#include <llvm/Config/llvm-config.h>
#include <llvm/Bitcode/BitcodeWriter.h>
#include <llvm/IR/Module.h>
#include <llvm/IR/IRBuilder.h>
#include <llvm/MC/MCAsmInfo.h>
#include <llvm/Support/CodeGen.h>
#include <llvm/Support/CommandLine.h>
#include <llvm/Support/MemoryBuffer.h>
#include <llvm/Support/raw_ostream.h>
#include <llvm/Target/TargetMachine.h>
#include <llvm/Transforms/Utils/SplitModule.h>
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

// Split a module into `parts` modules and hand each one to `callback` as
// bitcode, in partition order, as soon as it is written.
//
// The module is changed in place. Every local definition is first renamed
// with the prefix `__crystal_local.` (a prefix no C or Crystal external symbol
// uses), and SplitModule then makes every local an external symbol with
// hidden visibility, so references across parts resolve when the objects are
// linked and cannot collide with symbols of other objects in the link. Each
// part is serialized because LLVM contexts are not thread-safe: the receiver
// parses it into a context of its own and compiles it on any thread (LLVM's
// LTO `splitCodeGen` does the same). The callback owns the buffer it receives
// and must dispose of it; it must not unwind (it is called from C++).
//
// Returns the number of parts handed to `callback` (always `parts`), or 0
// without changing the module when it carries module-level assembly, which
// SplitModule cannot keep consistent across parts.
unsigned LLVMExtSplitModuleToBitcode(LLVMModuleRef M, unsigned parts,
                                     void (*callback)(void *data, unsigned index,
                                                      LLVMMemoryBufferRef buffer),
                                     void *data) {
  Module &module = *unwrap(M);
  if (!module.getModuleInlineAsm().empty())
    return 0;

  auto rename_local = [](GlobalValue &value) {
    if (value.isDeclaration() || !value.hasLocalLinkage())
      return;
    if (value.hasName())
      value.setName("__crystal_local." + value.getName());
    else
      value.setName("__crystal_local.unnamed");
  };
  for (Function &function : module)
    rename_local(function);
  for (GlobalVariable &variable : module.globals())
    rename_local(variable);
  for (GlobalAlias &alias : module.aliases())
    rename_local(alias);
  for (GlobalIFunc &ifunc : module.ifuncs())
    rename_local(ifunc);

  unsigned index = 0;
  SplitModule(
      module, parts,
      [&](std::unique_ptr<Module> part) {
        SmallString<0> bitcode;
        raw_svector_ostream stream(bitcode);
        WriteBitcodeToFile(*part, stream);
        part.reset();
        auto buffer = MemoryBuffer::getMemBufferCopy(
            StringRef(bitcode.data(), bitcode.size()), "crystal-release-part");
        callback(data, index++, wrap(buffer.release()));
      },
      /* PreserveLocals */ false, /* RoundRobin */ true);
  return index;
}

} // extern "C"
