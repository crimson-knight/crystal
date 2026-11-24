# Taking an upstream Crystal release into incremental-compilation

The routine used for 1.22.3 (`notes/upstream-1.22.3.md`), for every later upstream release.

1. **Fetch the tag** from https://github.com/crystal-lang/crystal.git
   (`git fetch https://github.com/crystal-lang/crystal.git refs/tags/X.Y.Z:refs/tags/X.Y.Z`) and
   record its commit. Count the gap: `git rev-list --count origin/incremental-compilation..X.Y.Z`.
2. **Branch** `memory-ceiling/upstream-X.Y.Z` from `origin/incremental-compilation` in a new worktree.
   When the gap spans patch releases, merge them one at a time, oldest first (1.21.1 before 1.22.3):
   small merges keep each conflict readable.
3. **Merge, never rebase**: `git -c merge.conflictstyle=zdiff3 merge --no-ff --no-commit X.Y.Z`.
   Resolve with these rules:
   - Where upstream changed the same code, take upstream's structure and re-apply the fork's change
     on top. Where upstream now ships a fix the fork backported (HTTP fixes, the SO_ERROR connect
     fix), take upstream's version.
   - Keep the fork's features working: module spill, stable names, IR skip, line patching,
     dispatch pruning, release units, memory budget, ELF `~at~` names, strict files, typed-once,
     infer reuse and persist (they need the `after_fork` hooks), compact AST nodes, Mica defaults.
   - Also check what merged **without** a conflict: removed APIs the fork still calls (1.22 dropped
     `Process.fork` and the `after_fork` hooks; the merge removed them silently), new macro-visible
     types (the memory census), new regex literals in stdlib, vendored shards and specs (Mica has no
     lookaround, possessive quantifiers or backreferences; the compiler aborts at start-up on such a
     constant). `git diff <old-base> X.Y.Z -- src lib spec | grep '^+' | grep -E '\(\?[<=!>]'` finds
     lookaround; also search for `++`, `*+`, `?+`, `}+` and `\1`.
   - CI files: take upstream's, then re-pin every image by `@sha256:` digest (Docker Hub registry
     API), every Action by full commit SHA, and keep the apt.llvm.org key check. Local reusable
     workflows use `./.github/...` (dep-pin-audit rejects `$/`). Vendored shards: pin the commit of
     the upstream version and compare the vendored source with that commit's tarball.
   - Write every non-trivial resolution and its reason in `notes/upstream-X.Y.Z.md`.
4. **Version**: `src/VERSION` and `shard.yml` come from the tag. Releases from the new base are
   `vX.Y.Z-incremental-1`, `-2`, and so on.
5. **Build**: type-check first (`build --no-codegen` with the pinned host, seconds), then
   `tools/build_compiler.sh`, smoke-test (`--version`, a hello world with a regex), then stage 2 with
   the stage-1 compiler.
6. **Checks on the merged head**: spec/compiler/semantic and codegen, spec/compiler-cli, the feature
   specs, the full std suite on both minis (`tools/remote_run.sh`, OpenSSL and zlib on,
   `TMPDIR=/tmp`), stage-2 self-host, Grant20 and Grant300 (default, `--memory-budget 4G`, strict copy)
   through `tools/run_build.rb` against the last release's numbers, `CRYSTAL_INFER_REUSE_VERIFY=1` on
   Grant20, and the Linux smoke + `elf_symbol_names` + std socket specs in one container job.
   Compare every std failure beyond the known ones with the upstream tag's own behavior.
7. **PR** against incremental-compilation with the conflict list, the version plan and the numbers;
   merge when green with `gh pr merge --match-head-commit <head>`. Then tell the Mica session
   (it owns the Homebrew tap) the new release name and that the tap's stdlib identity must be
   recomputed.
