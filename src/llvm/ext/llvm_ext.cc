#include <llvm/Config/llvm-config.h>
#include <llvm/ADT/DenseMap.h>
#include <llvm/ADT/STLExtras.h>
#include <llvm/ADT/StringExtras.h>
#include <llvm/ADT/StringSet.h>
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

#if LLVM_VERSION_MAJOR >= 17
// Gives the local definitions of a module that is emitted as several objects
// the names and the linkage they need so that one object can refer to what
// another one defines (see `LLVMExtSplitModuleToBitcode` for the rules).
class LinkPromoter {
public:
  explicit LinkPromoter(const Module &module)
      // A leading \1 asks the mangler to keep the name as written, without
      // the `_` global prefix Mach-O adds, so the promoted name starts with
      // `l`.
      : private_prefix(Triple(module.getTargetTriple()).isOSBinFormatMachO()
                           ? "\1l__crystal_private."
                           : "__crystal_private.") {}

  // Renames a local definition whose name could meet another object's
  // symbol in the link.
  void rename(GlobalValue &value) const {
    if (value.isDeclaration() || !value.hasLocalLinkage())
      return;
    // A promoted name is used by these objects alone, so it is mangled as
    // usual (apart from the Mach-O prefix above) even if the local's name
    // asked the mangler to keep it as written.
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
  }

  // Makes a local definition external and hidden, and names an unnamed one.
  static void externalize(GlobalValue &value) {
    if (value.hasLocalLinkage()) {
      value.setLinkage(GlobalValue::ExternalLinkage);
      value.setVisibility(GlobalValue::HiddenVisibility);
    }
    if (!value.hasName())
      value.setName("__llvmsplit_unnamed");
  }

  // Renames and then externalizes *value*.
  void promote(GlobalValue &value) const {
    rename(value);
    externalize(value);
  }

private:
  static bool is_plain_symbol_character(char character) {
    return isAlnum(character) || character == '_' || character == '.' ||
           character == '$';
  }

  StringRef private_prefix;
};

// Calls `callback` with every global value that `constant` refers to,
// looking through constant expressions and aggregates (but not through
// global variables' initializers). `visited` keeps a constant from being
// looked into twice.
template <typename Callback>
void LLVMExtForEachGlobalIn(const Constant *constant,
                            SmallPtrSetImpl<const Constant *> &visited,
                            Callback &&callback) {
  if (auto *value = dyn_cast<GlobalValue>(constant)) {
    callback(const_cast<GlobalValue *>(value));
    return;
  }
  if (!visited.insert(constant).second)
    return;
  for (const Use &operand : constant->operands())
    if (auto *operand_constant = dyn_cast<Constant>(operand.get()))
      LLVMExtForEachGlobalIn(operand_constant, visited, callback);
}

// Calls `callback` with every global value that the body of `function`
// refers to (its instructions' operands and its personality function).
template <typename Callback>
void LLVMExtForEachGlobalUsedBy(const Function &function,
                                SmallPtrSetImpl<const Constant *> &visited,
                                Callback &&callback) {
  if (function.hasPersonalityFn())
    LLVMExtForEachGlobalIn(function.getPersonalityFn(), visited, callback);
  for (const BasicBlock &block : function)
    for (const Instruction &instruction : block)
      for (const Use &operand : instruction.operands())
        if (auto *constant = dyn_cast<Constant>(operand.get()))
          LLVMExtForEachGlobalIn(constant, visited, callback);
}

// The named metadata in which a module split by
// `LLVMExtSplitOffIslandToBitcode` lists the definitions it promoted.
const char *const LLVMExtPromotionsMetadataName = "crystal.island.promotions";

// Records the names of `values` in the module's list of promotions.
void LLVMExtRecordPromotions(Module &module, ArrayRef<GlobalValue *> values) {
  if (values.empty())
    return;
  LLVMContext &context = module.getContext();
  NamedMDNode *promotions = module.getOrInsertNamedMetadata(LLVMExtPromotionsMetadataName);
  for (GlobalValue *value : values)
    promotions->addOperand(MDNode::get(context, MDString::get(context, value->getName())));
}

// Calls `callback` with every function that `function` calls directly.
template <typename Callback>
void LLVMExtForEachDirectCallee(const Function &function, Callback &&callback) {
  for (const BasicBlock &block : function)
    for (const Instruction &instruction : block)
      if (auto *call = dyn_cast<CallBase>(&instruction))
        if (Function *callee = call->getCalledFunction())
          callback(callee);
}
#endif

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

// Orders the module's functions and global variables by name, definitions
// first and then declarations, so that its bitcode does not depend on the
// order they were made in. (Unnamed ones keep their order.)
void LLVMExtSortModuleByName(LLVMModuleRef M) {
  Module &module = *unwrap(M);
  auto comes_first = [](GlobalValue *a, GlobalValue *b) {
    if (a->isDeclaration() != b->isDeclaration())
      return !a->isDeclaration();
    return a->getName() < b->getName();
  };

  std::vector<Function *> functions;
  for (Function &function : module)
    functions.push_back(&function);
  llvm::stable_sort(functions, comes_first);
  auto &function_list = module.getFunctionList();
  for (Function *function : functions)
    function_list.splice(function_list.end(), function_list, function->getIterator());

  std::vector<GlobalVariable *> globals;
  for (GlobalVariable &global : module.globals())
    globals.push_back(&global);
  llvm::stable_sort(globals, comes_first);
#if LLVM_VERSION_MAJOR >= 17
  for (GlobalVariable *global : globals) {
    module.removeGlobalVariable(global);
    module.insertGlobalVariable(global);
  }
#else
  auto &global_list = module.getGlobalList();
  for (GlobalVariable *global : globals)
    global_list.splice(global_list.end(), global_list, global->getIterator());
#endif
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

  LinkPromoter promoter(module);
  for (Function &function : module)
    promoter.rename(function);
  for (GlobalVariable &variable : module.globals())
    promoter.rename(variable);
  for (GlobalAlias &alias : module.aliases())
    promoter.rename(alias);
  for (GlobalIFunc &ifunc : module.ifuncs())
    promoter.rename(ifunc);

  // Make every local definition external and hidden, and name the unnamed
  // ones, so each part can refer to what another part defines.
  for (Function &function : module)
    LinkPromoter::externalize(function);
  for (GlobalVariable &variable : module.globals())
    LinkPromoter::externalize(variable);
  for (GlobalAlias &alias : module.aliases())
    LinkPromoter::externalize(alias);
  for (GlobalIFunc &ifunc : module.ifuncs())
    LinkPromoter::externalize(ifunc);

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

// Move the functions of self-contained namespaces out of an unoptimized
// module into an "island" module of their own and hand that module back as
// bitcode, so the two modules can be optimized and emitted on two threads.
//
// The island holds every defined function whose name, after an optional
// leading `*` or `~`, starts with one of the `prefix_count` strings of
// `prefixes`, and every defined function whose only uses are direct calls
// from island functions (repeated to a fixed point, which brings in the
// generic instances only the island calls, such as `Array(Regex::Mica::Node)`
// methods). Functions in a comdat or named by an alias stay where they are.
//
// So that inlining across the boundary keeps the hot paths fast, each module
// also gets `available_externally` copies of what it calls in the other: the
// island of the functions with at most `import_instruction_limit`
// instructions that its functions call directly (and of the small functions
// those call, `import_depth` levels deep), and of the constant global
// variables they read; the main module of the island's small functions that
// it calls. Global variables are defined in the main module only. Every
// function and variable keeps exactly one real definition, in its home
// module.
//
// Every definition one module refers to in the other is promoted the way
// `LLVMExtSplitModuleToBitcode` promotes local definitions, and everything
// else in the island is a declaration. The main module is changed in place:
// the island's functions become declarations (or `available_externally`
// copies) in it. The island is serialized because LLVM contexts are not
// thread-safe: the receiver parses it into a context of its own. The caller
// owns the returned buffer and must dispose of it.
//
// Returns null without changing the module when no function belongs to the
// island, or when `LLVMExtModuleCanBeSplit` is false for it.
LLVMMemoryBufferRef LLVMExtSplitOffIslandToBitcode(LLVMModuleRef M,
                                                   const char *const *prefixes,
                                                   unsigned prefix_count,
                                                   unsigned import_instruction_limit,
                                                   unsigned import_depth) {
  if (!LLVMExtModuleCanBeSplit(M))
    return nullptr;
#if LLVM_VERSION_MAJOR >= 17
  Module &module = *unwrap(M);

  SmallPtrSet<const GlobalObject *, 16> aliased_objects;
  for (const GlobalAlias &alias : module.aliases())
    if (const GlobalObject *object = alias.getAliaseeObject())
      aliased_objects.insert(object);
  auto can_move = [&](const Function &function) {
    return !function.isDeclaration() && !function.hasAvailableExternallyLinkage() &&
           !function.hasComdat() && function.hasName() &&
           !aliased_objects.contains(&function);
  };
  auto has_island_name = [&](const Function &function) {
    StringRef name = function.getName();
    if (name.starts_with("*") || name.starts_with("~"))
      name = name.drop_front(1);
    for (unsigned prefix_index = 0; prefix_index < prefix_count; ++prefix_index)
      if (name.starts_with(prefixes[prefix_index]))
        return true;
    return false;
  };

  // The island's functions: the named ones, then the ones that only they
  // call. A function can only join once one of its callers has joined.
  SmallPtrSet<Function *, 32> members;
  SmallVector<Function *, 1024> worklist;
  for (Function &function : module)
    if (can_move(function) && has_island_name(function)) {
      members.insert(&function);
      worklist.push_back(&function);
    }
  if (members.empty())
    return nullptr;
  auto is_island_call = [&](const Use &use) {
    auto *call = dyn_cast<CallBase>(use.getUser());
    return call && call->isCallee(&use) && members.contains(call->getFunction());
  };
  while (!worklist.empty()) {
    Function *member = worklist.pop_back_val();
    LLVMExtForEachDirectCallee(*member, [&](Function *callee) {
      if (members.contains(callee) || !can_move(*callee))
        return;
      if (!llvm::all_of(callee->uses(), is_island_call))
        return;
      members.insert(callee);
      worklist.push_back(callee);
    });
  }

  // The small functions each module calls in the other, followed
  // `import_depth` levels into their home module.
  auto can_import = [&](const Function &function) {
    return can_move(function) &&
           function.getInstructionCount() <= import_instruction_limit &&
           !function.hasFnAttribute(Attribute::NoInline);
  };
  auto collect_imports = [&](ArrayRef<Function *> roots, bool from_island,
                             SmallPtrSetImpl<Function *> &imports) {
    SmallVector<Function *, 256> level(roots.begin(), roots.end());
    for (unsigned depth = 0; depth <= import_depth && !level.empty(); ++depth) {
      SmallVector<Function *, 256> next_level;
      for (Function *caller : level)
        LLVMExtForEachDirectCallee(*caller, [&](Function *callee) {
          // A function from the island imports from the main module, and
          // the other way around; a copy calls within its home module.
          bool is_home = members.contains(callee) != from_island;
          if (!is_home || !can_import(*callee) || !imports.insert(callee).second)
            return;
          next_level.push_back(callee);
        });
      level = std::move(next_level);
    }
  };
  SmallVector<Function *, 1024> list_of_members(members.begin(), members.end());
  SmallVector<Function *, 1024> list_of_main_functions;
  for (Function &function : module)
    if (!function.isDeclaration() && !members.contains(&function))
      list_of_main_functions.push_back(&function);
  SmallPtrSet<Function *, 32> island_imports;
  SmallPtrSet<Function *, 32> main_imports;
  collect_imports(list_of_members, /* from_island */ true, island_imports);
  collect_imports(list_of_main_functions, /* from_island */ false, main_imports);

  // What the island's code refers to: the constants it reads are imported,
  // and every definition of the main module it names is promoted.
  SmallPtrSet<const Constant *, 32> visited;
  SmallPtrSet<GlobalValue *, 32> island_references;
  auto note_island_reference = [&](GlobalValue *value) { island_references.insert(value); };
  for (Function *function : members)
    LLVMExtForEachGlobalUsedBy(*function, visited, note_island_reference);
  for (Function *function : island_imports)
    LLVMExtForEachGlobalUsedBy(*function, visited, note_island_reference);
  SmallPtrSet<GlobalVariable *, 32> imported_constants;
  SmallVector<GlobalVariable *, 256> constant_worklist;
  for (GlobalValue *value : island_references)
    if (auto *variable = dyn_cast<GlobalVariable>(value))
      constant_worklist.push_back(variable);
  while (!constant_worklist.empty()) {
    GlobalVariable *variable = constant_worklist.pop_back_val();
    if (!variable->isConstant() || !variable->hasInitializer() ||
        variable->hasAvailableExternallyLinkage() || variable->hasComdat() ||
        variable->isThreadLocal() || !imported_constants.insert(variable).second)
      continue;
    LLVMExtForEachGlobalIn(variable->getInitializer(), visited, [&](GlobalValue *value) {
      island_references.insert(value);
      if (auto *referenced_variable = dyn_cast<GlobalVariable>(value))
        constant_worklist.push_back(referenced_variable);
    });
  }

  // What the main module's code (its functions, the copies it imports, its
  // variables' initializers, aliases and ifuncs) refers to in the island.
  SmallPtrSet<GlobalValue *, 32> main_references;
  auto note_main_reference = [&](GlobalValue *value) { main_references.insert(value); };
  visited.clear();
  for (Function *function : list_of_main_functions)
    LLVMExtForEachGlobalUsedBy(*function, visited, note_main_reference);
  for (Function *function : main_imports)
    LLVMExtForEachGlobalUsedBy(*function, visited, note_main_reference);
  for (const GlobalVariable &variable : module.globals())
    if (variable.hasInitializer())
      LLVMExtForEachGlobalIn(variable.getInitializer(), visited, note_main_reference);
  for (const GlobalAlias &alias : module.aliases())
    LLVMExtForEachGlobalIn(alias.getAliasee(), visited, note_main_reference);
  for (const GlobalIFunc &ifunc : module.ifuncs())
    LLVMExtForEachGlobalIn(ifunc.getResolver(), visited, note_main_reference);

  auto is_island_definition = [&](const GlobalValue *value) {
    auto *function = dyn_cast<Function>(value);
    return function && members.contains(function);
  };
  // Promoted in module order, so the names given to unnamed values do not
  // depend on where the sets keep their pointers.
  auto crosses_boundary = [&](GlobalValue &value) {
    if (is_island_definition(&value))
      return main_references.contains(&value);
    return !value.isDeclaration() && island_references.contains(&value);
  };
  // Each module records the local definitions it promoted, so they can be
  // made local again once both modules are optimized and the other one no
  // longer refers to them (see `LLVMExtInternalizeUnreferencedPromotions`).
  LinkPromoter promoter(module);
  SmallVector<GlobalValue *, 256> list_of_promoted_main_values;
  SmallVector<GlobalValue *, 256> list_of_promoted_island_functions;
  auto promote = [&](GlobalValue &value) {
    bool was_local = value.hasLocalLinkage();
    promoter.promote(value);
    if (!was_local)
      return;
    if (is_island_definition(&value))
      list_of_promoted_island_functions.push_back(&value);
    else
      list_of_promoted_main_values.push_back(&value);
  };
  for (Function &function : module)
    if (crosses_boundary(function))
      promote(function);
  for (GlobalVariable &variable : module.globals())
    if (crosses_boundary(variable))
      promote(variable);
  for (GlobalAlias &alias : module.aliases())
    if (crosses_boundary(alias))
      promote(alias);
  for (GlobalIFunc &ifunc : module.ifuncs())
    if (crosses_boundary(ifunc))
      promote(ifunc);

  ValueToValueMapTy value_map;
  std::unique_ptr<Module> island = CloneModule(module, value_map, [&](const GlobalValue *value) {
    if (auto *function = dyn_cast<Function>(value))
      return members.contains(function) || island_imports.contains(function);
    if (auto *variable = dyn_cast<GlobalVariable>(value))
      return imported_constants.contains(variable);
    return false;
  });
  for (Function *function : island_imports)
    cast<GlobalValue>(value_map[function])->setLinkage(GlobalValue::AvailableExternallyLinkage);
  for (GlobalVariable *variable : imported_constants)
    cast<GlobalValue>(value_map[variable])->setLinkage(GlobalValue::AvailableExternallyLinkage);
  // The declarations of everything else the main module holds.
  auto erase_unused_declarations = [](Module &target) {
    for (Function &function : make_early_inc_range(target))
      if (function.isDeclaration() && function.use_empty())
        function.eraseFromParent();
    for (GlobalVariable &variable : make_early_inc_range(target.globals()))
      if (variable.isDeclaration() && variable.use_empty())
        variable.eraseFromParent();
  };
  erase_unused_declarations(*island);
  LLVMExtRecordPromotions(*island, list_of_promoted_island_functions);
  LLVMExtRecordPromotions(module, list_of_promoted_main_values);

  SmallString<0> bitcode;
  raw_svector_ostream stream(bitcode);
  WriteBitcodeToFile(*island, stream);
  island.reset();

  // The main module keeps a copy of the small island functions it calls and
  // a declaration of the others it refers to.
  for (Function *function : members)
    if (main_imports.contains(function))
      function->setLinkage(GlobalValue::AvailableExternallyLinkage);
    else
      function->deleteBody();
  for (Function *function : members)
    if (function->isDeclaration() && function->use_empty())
      function->eraseFromParent();

  auto buffer = MemoryBuffer::getMemBufferCopy(StringRef(bitcode.data(), bitcode.size()),
                                               "crystal-release-island");
  return wrap(buffer.release());
#else
  return nullptr;
#endif
}

// Call `callback` with the name of every function and global variable that
// the module declares and uses: what it needs another object of the link to
// define. Declarations of intrinsics are left out.
void LLVMExtForEachReferencedDeclaration(LLVMModuleRef M,
                                         void (*callback)(void *data, const char *name,
                                                          size_t length),
                                         void *data) {
  Module &module = *unwrap(M);
  for (const Function &function : module)
    if (function.isDeclaration() && !function.isIntrinsic() && !function.use_empty())
      callback(data, function.getName().data(), function.getName().size());
  for (const GlobalVariable &variable : module.globals())
    if (variable.isDeclaration() && !variable.use_empty())
      callback(data, variable.getName().data(), variable.getName().size());
}

// Make local again (internal, default visibility) every definition that
// `LLVMExtSplitOffIslandToBitcode` promoted in this module and whose name is
// not among the `name_count` strings of `referenced_names` (the declarations
// the other, optimized module still uses), so that an optimization pass such
// as `globaldce` can remove the ones no longer used here either. The record
// of promotions is removed.
//
// Returns the number of definitions made local.
unsigned LLVMExtInternalizeUnreferencedPromotions(LLVMModuleRef M,
                                                  const char *const *referenced_names,
                                                  unsigned name_count) {
#if LLVM_VERSION_MAJOR >= 17
  Module &module = *unwrap(M);
  NamedMDNode *promotions = module.getNamedMetadata(LLVMExtPromotionsMetadataName);
  if (!promotions)
    return 0;

  StringSet<> referenced;
  for (unsigned name_index = 0; name_index < name_count; ++name_index)
    referenced.insert(referenced_names[name_index]);

  unsigned internalized = 0;
  for (const MDNode *promotion : promotions->operands()) {
    StringRef name = cast<MDString>(promotion->getOperand(0))->getString();
    GlobalValue *value = module.getNamedValue(name);
    if (!value || value->isDeclaration() || value->hasLocalLinkage() ||
        referenced.contains(name))
      continue;
    value->setLinkage(GlobalValue::InternalLinkage);
    value->setVisibility(GlobalValue::DefaultVisibility);
    internalized += 1;
  }
  module.eraseNamedMetadata(promotions);
  return internalized;
#else
  return 0;
#endif
}

} // extern "C"
