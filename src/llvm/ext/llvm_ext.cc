#include <llvm/Config/llvm-config.h>
#include <llvm/IR/IRBuilder.h>
#include <llvm/MC/MCAsmInfo.h>
#include <llvm/Support/CodeGen.h>
#include <llvm/Support/CommandLine.h>
#include <llvm/Target/TargetMachine.h>
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

// Forward declarations of WebAssembly backend cl::opt flags.
// WasmEnableEH: master switch for WASM exception handling.
// WasmUseLegacyEH: when false, emits new try_table/exnref format instead of
//   legacy try/catch. Defaults to true in LLVM, we set it to false.
namespace llvm { namespace WebAssembly {
  extern cl::opt<bool> WasmEnableEH;
  extern cl::opt<bool> WasmUseLegacyEH;
}}

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
// 3. Sets the WasmEnableEH cl::opt flag to true (used by the legacy pass
//    manager's addIRPasses() to decide whether to add WasmEHPrepare or
//    LowerInvoke). Without this, invoke instructions are stripped to calls.
// 4. Sets the WasmUseLegacyEH cl::opt flag to true to emit legacy try/catch
//    format instead of new try_table/exnref instructions.
//
// On LLVM 22+, steps 1-2 are handled by LLVMTargetMachineOptionsSetExceptionModel
// in the C API, so this function only sets the cl::opt flags (steps 3-4).
//
// We use legacy EH (try/catch) instead of new EH (try_table/exnref) because
// Binaryen's Asyncify pass does not support the new try_table instructions.
// After Asyncify, we run --translate-to-exnref to convert to the new format.
void LLVMExtSetWasmExceptionHandling(LLVMTargetMachineRef T) {
#if !LLVM_VERSION_GE(22, 0)
  // Pre-LLVM 22: Must set ExceptionModel manually since the C API doesn't
  // expose LLVMTargetMachineOptionsSetExceptionModel.
  auto *TM = reinterpret_cast<TargetMachine *>(T);
  TM->Options.ExceptionModel = ExceptionHandling::Wasm;
  const_cast<MCAsmInfo *>(TM->getMCAsmInfo())
      ->setExceptionsType(ExceptionHandling::Wasm);
#endif
  // cl::opt flags are still needed for the WebAssembly backend regardless
  // of LLVM version.
  llvm::WebAssembly::WasmEnableEH = true;
  llvm::WebAssembly::WasmUseLegacyEH = true;
}

} // extern "C"
