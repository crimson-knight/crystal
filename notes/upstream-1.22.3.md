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
| `codegen/codegen.cr`: the class-name pointer is initialized with the map global itself | Upstream builds the initializer with `gep(map_type, map, 0, 0)`; its index constants come from the current LLVM context, and the fork gives each type module its own context, so at the end of codegen they were not the main module's ("Global variable initializer type does not match global variable type", 4 codegen specs). With opaque pointers that GEP is the map's address; LLVM before 15 keeps the GEP. |
| `spec/compiler/codegen/def_spec.cr`, `spec/std/string_spec.cr`: upstream specs with lookaround | The two #17424 checks test the `:type_id` reads without a lookbehind; string_spec's "empty match + advanced offset" is left out on Mica, as the neighboring lookahead examples already are. |
| `src/compiler/frontend_main.cr`, `spec/compiler/semantic/inference_state_release_spec.cr`: `define_crystal_constants` | Crystal 1.22 defines `Crystal::VERSION` and its peers when the compiler sets up a program, no longer in `Program#initialize`; the WASM frontend and one spec helper made their own Program. |
| `spec/std/exception/call_stack_spec.cr`: upstream's two new backtrace examples build with `--dsymutil` | Development builds skip dsymutil on macOS in this fork (#35); the file's other examples already pass the flag. |

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
- PR #45 (HTTP TLS as an opt-in) merged as ce52bb548; merged into this branch as 8ce8e9591.
  #45 split `src/http/web_socket.cr` into `web_socket/core.cr` (server side, no HTTP::Client) and
  `web_socket/client.cr`, moved `bind_tls` to `http/server/tls.cr`, and dropped the http
  require from `mime/media_type.cr`. Upstream 1.22 had changed the same files, so the merge
  conflicted:

  | File | Resolution |
  |---|---|
  | `src/http/web_socket.cr` | #45's version (it only requires `./web_socket/core` and `./web_socket/client`). Upstream 1.22's receive-loop fixes moved with the code: `web_socket/core.cr` now has upstream's `@current_message_opcode` check (#17552: a continuation frame whose opcode differs from the message being assembled closes with ProtocolError) and the control-frame handling (#17553: a fragmented ping or pong closes with ProtocolError; a ping or pong in the middle of a fragmented message is answered from its own payload, without touching `@current_message`). Checked line by line against `git diff 1.21.0 1.22.3 -- src/http/web_socket.cr`. |
  | `src/mime/media_type.cr` | Upstream's version (#17306 removed both `require "uri"` and `require "http"`; #45 removed only `http`). |
  | `src/http/web_socket/protocol.cr` (auto-merged) | Carries upstream's masked-frame checks (#17562: `header_masked` against `@masked`, `read_payload` unmasks `unless @masked`) and #45's removal of the client constructor, which now lives in `web_socket/client.cr`, plus the fork's `crystal/digest/sha1` for the key challenge. |
  | `src/http/server.cr`, `server/tls.cr`, `handlers/websocket_handler.cr` (auto-merged) | Upstream's `@processor.process(io)` (the fork's `skip_request_body` stays in `request_processor.cr`); `bind_tls` in `tls.cr` is unchanged by upstream 1.22. |

  A plain `require "http/server"` program built at 8ce8e9591 links only `libgc` and `libSystem`
  (`otool -L`): no libssl, libcrypto, libz or libpcre.

## Checks on the merged head

Compiler built with the pinned host (`tools/build_compiler.sh`, 50289ec1…) from b045c3757 (the last
compiler change; 5dc83c8f1 after it changes one spec only). Spec counts are examples / failures /
errors / pending.

| Check | Where | Result |
|---|---|---|
| spec/compiler/codegen | laptop, b045c3757 | 1963 / 0 / 2 / 6 (the 2 errors are the known `special_vars_spec.cr:18`) |
| spec/compiler/semantic | m4-mini-02, b045c3757 | 3477 / 0 / 1 / 9; the 1 error was a spec helper without the Crystal constants, fixed in 5dc83c8f1 (that file plus block_instance_sharing: 39 / 0 / 0) |
| spec/compiler/semantic | m4-mini-01, 5dc83c8f1 | 3477 / 0 / 0 / 9 |
| spec/compiler-cli + infer_reuse + incremental_rebuild + memory_budget + strict + c_allocator + compiler_spec | laptop, b045c3757 | 139 / 0 / 0 / 0 |
| Feature specs (strict, type_once, generic_type_once, ir_skip, line_patch, stable_numbering, release_units, dispatch_prune, elf_symbol_names, infer_reuse, infer_persist, incremental_rebuild, memory_budget) | inside the suites above | all pass |
| spec/std_spec.cr, OpenSSL and zlib on, TMPDIR=/tmp | m4-mini-01, b045c3757 | 18330 / 0 / 1 / 34 (the known `process_spec.cr:642`, which was `:677` before upstream dropped the fork specs) |
| spec/std_spec.cr, same | m4-mini-02, b045c3757 | 18330 / 0 / 1 / 34 (same) |
| spec/std/openssl/ (with #44's bio_spec) | laptop and m4-mini-01 | 117 / 0 / 0 / 2 (laptop); with call_stack, exception, socket, process: 493 / 0 / 1 (known) / 7 (m4-mini-01, 418628057) |
| spec/std/http + spec/std/mime + bio_spec, OpenSSL on | laptop, 8ce8e9591 | 754 / 0 / 0 / 0 |
| #45's `tls_opt_in_spec.cr` + `web_socket_spec.cr` | laptop, 8ce8e9591 | 52 / 0 / 0 / 0 (all 7 opt-in cases; upstream's masked-frame and mixed-opcode cases) |
| spec/std_spec.cr, OpenSSL and zlib on, TMPDIR=/tmp | m4-mini-02, 8ce8e9591 | 18337 / 0 / 1 / 34 (the known `process_spec.cr:642`; 7 more examples from #45) |
| Stage-2 self-host (release) | laptop | built, `Crystal 1.22.3 [b045c3757]`, runs a program; rebuilt at the head: stage 1 `Crystal 1.22.3 [8ce8e9591]` from the pinned host, stage 2 built with it, runs a program |
| Stage-2 self-host, non-release `--threads 8 --incremental`, then a one-line edit in `codegen/fun.cr` | laptop, 418628057 | clean 36 s, edit 24 s, the rebuilt compiler runs a program |
| Linux (Docker, linux-4gb image, 4 CPUs, 5 GB): compiler cross-compiled on the Mac and linked in the container; smoke program (fiber + channel + Mica regex + `Crystal::USER_FLAGS`); `elf_symbol_names_spec` + `spec/std/socket/` | one cluster-pool job, key mc-step7 | smoke prints `linux smoke 1.22.3 2 1,2,3 ["smoke"]`; specs 211 / 0 / 0 / 7 (IPv6 pending in the container) |
| `CRYSTAL_INFER_REUSE_VERIFY=1`, Grant20, build server, -O0: clean, body edit (+3 lines), restore, new method, restore | laptop, tools/run_build.rb | every edit reused (0.25 to 0.43 s re-typing), 46,111 to 46,112 typed defs compared, **0 differences**, checks 3/3 on all 5 builds |

Not a textual conflict but found by these checks: the markd regexes (start-up abort), the
lookaround specs, the class-name map initializer (4 codegen errors), the two spec helpers and the
WASM frontend without `Crystal::VERSION`, and the two backtrace specs without `--dsymutil`. One stage-2 attempt failed with
"No such file or directory" while spec suites shared `~/.cache/crystal` with it (the cache cleanup
keeps only the newest folders); with its own `CRYSTAL_CACHE_DIR` it builds.

## Grant builds (tools/run_build.rb, this laptop, `--threads 8 -Duse_pcre2`, -O3 release)

Peak footprint is the primary number. Wall times depend on load: the first series ran beside this
merge's own spec suites, stage-2 build and Linux cross-compile; the "quiet" row ran with the laptop
at a load average near 10 from other agents.

| Build | Before (1.21 base) | Merged 1.22.3 (b045c3757) | Checks |
|---|---|---|---|
| Grant20 | 0.79 GB, 24.0 s (01d23a29f, this session) | 0.77 GB, 20.2 s (quiet); 0.87 GB, 39.7 s (loaded) | 3/3 |
| Grant300 default | 4.71 GB, 304 s (incremental-10 release check, rel10-g300-default) | **4.63 GB, 282 s** (quiet); 4.69 GB, 464 s (loaded) | 3/3 |
| Grant300 `--memory-budget 4G` | 4.31 GB, 309 s (rel10-g300-budget4g) | **4.21 GB**, 338 s (loaded) | 3/3 |
| Strict copy grant300-sg `--memory-budget 4G` | 3.86 GB, 273 s (imm-g300-sg-b4g) | **3.74 GB**, 213 s (loaded) | 3/3 |

Runs: `runs/20261124T023349Z-u1223f2-g300`, `20261124T023836Z-u1223f2-g20`, `20261124T015625Z-u1223f-g20`,
`20261124T015706Z-u1223f-g300`, `20261124T020521Z-u1223f-g300-b4g`, `20261124T021120Z-u1223f-g300sg-b4g`,
baseline `20261124T013647Z-base01d-g20` (all under memory-ceiling-20261120/).
No regression in memory: every Grant300 peak is 0.08 to 0.12 GB lower than on the 1.21 base.
