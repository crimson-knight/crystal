# Merging upstream Crystal 1.22.3 into incremental-compilation

Branch `memory-ceiling/upstream-1.22.3`, from `origin/incremental-compilation` at 01d23a29f.
Upstream tags fetched from https://github.com/crystal-lang/crystal.git:

| Tag | Commit |
|---|---|
| 1.21.0 (the fork's old base) | 57cf7da5094db6c5d3c058c6d054a757b5ced19e |
| 1.21.1 | 73ea5c2b1bc3b3ac0ba400aa9da77af96f63d6ef |
| 1.22.3 | 3462c0774d5353a76c5f95cf51cea597ba7b8f29 |

Two merge commits, never a rebase: first 1.21.1 (9 commits, small), then 1.22.3 (293 more).
The fork was 302 commits behind 1.22.3 and 414 commits ahead of it.

## Merge 1: 1.21.1 (3 conflicting files)

| File | Resolution | Why |
|---|---|---|
| `src/crystal/event_loop/{libevent,polling}.cr`, `src/crystal/system/unix/socket.cr`, `src/lib_c/{aarch64,x86_64}-darwin/c/sys/socket.cr` | upstream | Upstream #17436 is the same `SO_ERROR` connect fix the fork carried as #41 (macOS 27). Taking upstream removed a duplicate `system_error` and a duplicate `SO_ERROR` constant that the textual merge produced. |
| `src/http/server/request_processor.cr` | fork | Keeps the fork's `skip_request_body` helper (#23), which wraps upstream's `skip_to_end` and keeps its 32 KiB buffer off every connection's stack. |

## Merge 2: 1.22.3 (28 conflicting files)

### Compiler: codegen

| File | Resolution | Why |
|---|---|---|
| `codegen/fun.cr` (`target_def_fun`) | fork's path, plus upstream #17637 re-applied | The fork's `resolve_target_def_fun` (module spill, IR skip, deferred generation, owner-shape sharing) replaces upstream's three-line body. Upstream #17637 declares lib funs and LLVM intrinsics in the current module instead of in the main module and copying the declaration (a copy fails for a parameter with a `range` attribute, e.g. `llvm.prefetch`). Re-applied as `declare_external_in_current_module`, which declares from the signature only and skips `codegen_fun`'s bookkeeping (no trace frame, no generated-name entry), so IR skip and module reuse see nothing new. A replayed trace (`request_target_def_fun`) asks nothing for an External: it has no body. |
| `codegen/call.cr` (dispatch) | both | Upstream #17424 skips the owner's type id when the owner is not passed at run time (`obj_type_id` is now nilable). The fork's dispatch pruning (#40) is kept around it; its "unreachable type" error names the owner from a string constant when there is no type id (`dispatch_type_name`). |
| `codegen/llvm_id.cr` | both | Upstream #17425 gives enum types their ids up front (`PrimitiveType \| EnumType`); the fork's `new_id` keeps ids stable across builds (#21). |
| `codegen/codegen.cr` (initialize) | both | Fork: `discard_local_value_names`, `ModuleInfo` for the main module. Upstream #17672: `main_returns_value` (main returns a value only for `Program#run`/evaluate). |
| `codegen/codegen.cr` (class-name map) | upstream's structure, fork's IR-skip effect on top | Upstream #17502 reads the class-name map through a pointer global (`__crystal_type_id_to_class_name_ptr`) defined at the end of codegen, which solves the same problem as the fork's `[0 x String]` declaration with a definition at the end (a new type no longer changes every module that reads the map). Took upstream's `codegen_typeinfo`; the fork's `define_type_id_to_class_name_map` and `@uses_type_id_to_class_name_map` are gone. Kept on top: `record_ir_effect(ClassNameMap)` (a skipped module's replay sets `@needs_typeinfo`), `finish_ir_skip` runs before `codegen_typeinfo`, and the map's length is `llvm_id.id_limit` (kept ids can leave gaps; unused ids map to a null string). |
| `compiler.cr` (`new_program`) | both | Fork's `shared` flag plus upstream's `user_flags` (new `Crystal::USER_FLAGS` / `ALL_FLAGS`). |
| `compiler.cr` (`fork_codegen`, `fork_workers`) | upstream (removed) | Upstream #16417 dropped forked codegen; `parallel_codegen` already only uses threads, and the fork's parallel object stage is its own worker *processes* (`crystal internal-codegen-worker`, spawned, not forked). The fork's edit to the removed code (syncing the reuse flag from a child) has no caller left. Kept the fork's `print_macro_run_stats(program, io)` signature. |
| `compiler.cr` (`compile_to_object`) | both | Upstream added `file_name`/`optimize` for `--emit obj` from a fresh module (cross compile) and moves with `FileUtils.mv`. Fork: a unit split into parts writes one object per part, and the target machine is disposed. A part-split unit still goes to `compile_parts_to_objects` when it writes its own object; an explicit file name writes the whole module. |
| `semantic/memory_census.cr` (not a textual conflict) | fork, adjusted | Upstream's new private `Crystal::LRUCache::Node(K, V)` broke the census macro (a private generic's instances report `private? == false`); added to the census exclusions. |

### Runtime

| File | Resolution | Why |
|---|---|---|
| `crystal/event_loop/{epoll,kqueue,polling,libevent,io_uring}.cr`, `crystal/system/unix/signal.cr` (`after_fork` hooks) | fork, against upstream #17367 | Upstream dropped `Process.fork` and every `after_fork` hook. The fork's build server (`Crystal::InferReuse.fork_process`, infer reuse #31/#37 and infer persist #43) forks with one scheduler thread and needs them: a new event loop, its own signal pipe and loop, an empty child table (`SignalChildHandler.after_fork`). The public `Process.fork`, `Crystal::System::Process.fork` and `Process.after_fork_child_callbacks` stay removed, as upstream has it. The hooks are now unconditional (they were guarded by `-Dwithout_mt`; with upstream's removal the guarded parent method vanished and `super` failed). |
| `crystal/event_loop/wasi.cr` | fork's WASI event loop, ported to upstream's API | Upstream moved the select timeout action from `Fiber` to the event (`add(timeout, timeout_select_action)`, `Fiber.timeout` removed). The fork's WASI loop (#29) stores the action on its `Wasi::Event` and checks `time_expired?` when the timer fires. |
| `crystal/system/wasi/process.cr` | fork, minus `fork` | Fork's WASI messages and `prepare_args`/`spawn` shape (which matches upstream's Unix and Windows); `fork` removed as upstream did. |
| `crystal/system/wasi/file_descriptor.cr` | upstream's API, fork's messages | Upstream replaced `system_flock_*`/`flock` with `system_lock(blocking, exclusive)`/`system_unlock`. |
| `gc/boehm.cr` | both | Fork's `wasm32` guard around the stop-the-world functions, plus upstream's `GC_do_blocking`. |

### Standard library

| File | Resolution | Why |
|---|---|---|
| `src/http/common.cr`, `spec/std/http/request_spec.cr` | upstream | Every fork change here was a backport of an upstream fix that 1.22.3 now has (#17140, #17317, #17337, #17476/#17531, #17898, #17902, #17903, #17904). After the merge `src/http` equals upstream 1.22.3 except the fork's own two changes: `skip_request_body` (#23) and the WebSocket handshake on the standard library's SHA-1 (#34). |

### Build files and CI

| File | Resolution | Why |
|---|---|---|
| `shard.yml`, `shard.lock`, `lib/.shards.info` | upstream's markd 0.6.0, pinned by commit | Upstream vendors markd 0.6.0. Pinned to the v0.6.0 commit 9db69c0aba807d6186903a0b5fcadc1450bc2be4 (tag object 631635d7). The vendored `lib/markd/src` was checked against that commit's tarball (sha256 dc8c8713…aed4): identical except the fork's lookahead-free code-fence regex (Mica regex, #19), which the merge kept. |
| `.github/workflows/*.yml` (12 files) | upstream, re-pinned | Upstream moved CI to crystallang/crystal 1.21.0 images and split the Windows jobs into `win_steps.yml`/`win_build_libs.yml`. Took upstream and re-applied the fork's pinning: images by digest (`1.21.0-build@sha256:34ac3d5d…94c3`, `1.21.0-alpine@sha256:82ed00e2…10fc`, read from Docker Hub's registry API), every Action by full commit SHA (the fork's existing pins; `actions/setup-python` v7.1.0 = 6d4fd22b), and the apt.llvm.org key verified by sha256 and bound with `signed-by` on upstream's new LLVM matrix. The fork's Mica regex and YAML engine jobs are unchanged. |
| `.github/workflows/{mingw-w64,win,win_steps}.yml` (reusable workflow calls) | the fork's `./.github/...` form | Upstream #17513 switched local reusable-workflow calls to GitHub's newer `$/.github/...` self-repository syntax. Both resolve to the same commit, but `dep-pin-audit` reads `$/` as an unpinned ref and blocks the commit, so the calls keep the `./` form the fork already used. |

## Fixes after the merge (not textual conflicts)

| Change | Why |
|---|---|
| `lib/markd`: table regexes rewritten for Mica | markd 0.6.0 added GFM tables with a possessive quantifier (`:{0,1}+`) and a lookbehind (`(?<!\\)\|`). The compiler (Mica regex by default) aborted at start-up while initializing that constant. The heading separator drops the `+` (Mica never backtracks, so possessive and greedy match the same strings); the cell separator became `Markd::Rule.table_cell_separator?` and `.split_table_cells` (a `|` not preceded by a backslash). Checked against PCRE2 on the original patterns: 20 inputs, 0 differences. |

## Version and release names

- `src/VERSION` and `shard.yml` say `1.22.3` (both came from the upstream tag; `crystal --version`
  prints `Crystal 1.22.3 [<commit>]`).
- Release tags from this merge on: `v<upstream version>-incremental-<n>`, with `<n>` starting at 1 for
  each upstream version. The first release from this base is **`v1.22.3-incremental-1`**. The 1.21
  line ends at `v1.21.0-incremental-10` (cut from 01d23a29f, alongside this merge). When the fork
  takes upstream 1.22.4 or 1.23.0, numbering restarts: `v1.23.0-incremental-1`.
- The Homebrew formula (`crimson-knight/homebrew-agent-crystal`, `agent-crystal`) takes its version
  from the tag, so `brew` sees `1.22.3-incremental-1` as newer than `1.21.0-incremental-10`
  (Homebrew compares `1.22.3` > `1.21.0` first). The tap's stdlib identity (file list and hashes of
  `src/`) has to be recomputed: this merge adds, removes and changes many stdlib files.

## Later changes on incremental-compilation

- PR #44 (lazy OpenSSL BIO method table, `src/openssl/bio.cr`, new `spec/std/openssl/bio_spec.cr`)
  merged as 9e4a6613f after this branch started; merged into this branch (clean, no conflicts) so
  the PR carries it. `bio_spec.cr` runs with the std suite on both minis and on its own.
