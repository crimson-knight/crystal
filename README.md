# Crystal Alpha — fast rebuilds fork

A Crystal compiler fork with incremental rebuilds. On a ~8k line Amber app
opted in to strict signatures, a method body or template edit rebuilt in
~0.3s instead of 12s, and a rebuild without changes was skipped (0.07s).

Even in an LLM-driven world, clear and maintainable source code is still
valuable. I'm not a big fan of LLMs blindly turning everything into very
verbose Assembly or low-level Rust. The compiler should handle the lower-level
complexity deterministically, producing the exact same result every time.

The goal is to make Crystal fast enough for an LLM-heavy development workflow
without sacrificing readability. Current Crystal compilation is effectively
unusable in an LLM-driven workflow: LLMs need fast feedback and multiple
quick development cycles, while a large Crystal project can spend hours
compiling instead of iterating.

It's built for both ways of writing code today:

- **With an LLM (Claude Code, other agents):** the agent edits several files
  without a build per step (`crystal-alpha watch hold`), then gets its errors
  from `crystal-alpha watch build`. Explicit signatures are available when a
  project opts in to strict signatures.
- **By hand:** keep `crystal-alpha run` open in a terminal; save a file and the
  program restarts with the change before you've switched windows. Declared
  return types read as documentation when you choose to declare them.

Both can work on the same project at once if needed: the agent edits, you keep
`crystal-alpha run` open, and it rebuilds once when the agent is done.

## Setup

1. **Install the compiler** with the `crystal-alpha` command (also available
   as `acrystal`). For a source install, use the appropriate LLVM and Crystal
   build dependencies for your platform:

   ```sh
   make install release=1 interpreter=1 PREFIX=~/.local/opt/crystal-alpha
   ln -sfn ~/.local/opt/crystal-alpha/bin/crystal ~/.local/bin/crystal-alpha
   ln -sfn crystal-alpha ~/.local/bin/acrystal
   crystal-alpha watch --help | grep hold
   ```

   The man page step needs `asciidoctor`; if it fails, the compiler is still
   installed. Use the separately packaged `shards-alpha` toolchain. If linking
   fails on bundled libraries, resolve the installation's library paths.

2. **Optional: opt in to strict signatures.** Existing projects compile with
   their inferred return types by default. To migrate, add return types and
   then enable strict mode in the build:

   ```sh
   crystal-alpha tool annotate --dry-run   # the return types it would add
   crystal-alpha tool annotate             # add them
   crystal-alpha build --strict-signatures # lists what's left to type
   ```

   Commit first, so the change is easy to review. Set
   `CRYSTAL_STRICT_SIGNATURES=1` to opt in across commands;
   `--no-strict-signatures` overrides that environment setting.

## Prepare Claude Code (or another agent)

Put these hooks in the project's `.claude/settings.json` (also printed by
`crystal-alpha watch hooks`). They hold builds while Claude edits and release
them when it stops, so a multi-file edit is built once:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Edit|Write|MultiEdit|NotebookEdit",
        "hooks": [{ "type": "command", "command": "crystal-alpha watch hold claude" }]
      }
    ],
    "Stop": [
      {
        "hooks": [{ "type": "command", "command": "crystal-alpha watch release" }]
      }
    ]
  }
}
```

And add this to the project's `CLAUDE.md` (or `AGENTS.md` for other agents):

~~~~markdown
## Crystal toolchain (crystal-alpha fork)
- `crystal-alpha watch --help` must list `hold` and `build`; if not, the upstream
  compiler is on PATH: tell the user.
- Strict signatures are off by default. If this project opts in through
  `--strict-signatures` or `CRYSTAL_STRICT_SIGNATURES=1`, every project `def`
  needs a return type. For many methods, run `crystal-alpha tool annotate` and
  review what it adds. Otherwise, inferred return types remain valid.
- The user keeps `crystal-alpha run` (or `crystal-alpha watch`) running. Check
  its state with `crystal-alpha watch status` before starting another watcher.
- After your edits, run `crystal-alpha watch build`: it builds what changed
  and prints the errors; exit 1 = fix them.
  Exit 2 = no watcher: use `crystal-alpha build --no-codegen` to type check.
- Without the hooks, run `crystal-alpha watch hold claude` before editing.
- Specs: `crystal-alpha spec --affected` runs just the examples your edits reach
  (fast with the watcher); run plain `crystal-alpha spec` before finishing.
  A single file or example: `crystal-alpha spec [spec/file_spec.cr:LINE]`.
- Eligible method body edits and added methods take the faster path; changing
  signatures, removing methods or adding types rebuilds fully.
- Format: `crystal-alpha tool format`.
~~~~

## Usage

In a shard, commands find the main file from `shard.yml` (first target's
`main`, else `src/<name>.cr`):

```sh
crystal-alpha run      # build, run, rebuild + restart on every change (in a terminal)
crystal-alpha build    # build; skipped if nothing changed
crystal-alpha spec     # run the specs; skipped build if nothing changed
```

`crystal-alpha run file.cr` runs once as before; `--watch` / `--no-watch` choose.
`crystal-alpha watch` rebuilds without running.

While `crystal-alpha run` or `crystal-alpha watch` is running, the other
commands use it: `crystal-alpha build` gets its current executable, and
`crystal-alpha spec` can keep its program typed for later edits. Other
programs (the hooks above, an agent, a script) talk to it as well:

```sh
crystal-alpha spec --affected     # run only the examples reaching code changed since the last spec run
crystal-alpha watch hold claude   # don't build while editing
crystal-alpha watch release       # build what changed, once
crystal-alpha watch build         # build now, wait, print errors (exit 0 ok, 1 failed, 2 no watcher)
crystal-alpha watch status        # result of the last build
```

With strict signatures enabled, method body and template edits can take the
fast partial codegen path (~0.3s in the benchmark below). With strict mode
off, a body edit can still be typed incrementally if its inferred return type
and raising behavior stay the same. A changed inferred type falls back to a
full compilation; a trivial body that may be inlined causes full codegen.
Signature changes, new types, removed methods and top-level macro inputs also
rebuild fully.

## Why strict signatures

When enabled, strict signatures require every project `def` (outside `lib/`
and the standard library) to declare a return type. That declared type is what
callers see, so an eligible body edit needs only local typing and codegen.
Annotated code still compiles with upstream Crystal.

How it works: `IC_PHASE_8_STRICT_SIGNATURES.md`. Incremental caching and
`--no-incremental`: `INCREMENTAL_PLAN.md`.

## What's different from upstream Crystal

> [!WARNING]
> **Opting in to strict signatures changes how project code is typed.**
> Shards you depend on (in `lib/`) are exempt and compile unchanged. If you
> opt in while developing a shard or app, its own methods need annotations:
> of 43 popular shards whose specs we could compile, 42 had methods without a
> return type (median 17, up to 847), and in 5 (amber, asset_pipeline,
> lucky, shards, vips) existing return types broke callers that relied on
> the narrower inferred type (point 2 below). `crystal-alpha tool annotate`
> does most of the first part; the second needs a human (or an agent) to
> make the declared types precise. Leave strict mode off for code
> you don't want to migrate.

Things to check when switching a project or system to this compiler:

1. **Strict signatures are off by default.** `--strict-signatures` or
   `CRYSTAL_STRICT_SIGNATURES=1` enables them for project code (the current
   directory, except `lib/` and anything on `CRYSTAL_PATH`). Every `def` then
   needs a return type; `initialize` and methods generated by macros are
   exempt. `--no-strict-signatures` overrides an environment opt-in.
2. **In strict mode, a declared return type is what callers see.** Upstream,
   `def foo : Int32?`
   whose body returns an `Int32` has type `Int32` at call sites; here it's
   `Int32?`. Code relying on the narrower type (arithmetic on the result,
   `typeof`, an overload only the narrow type matches) fails to compile:
   declare the precise type (`: Int32`) or handle the wider one. A class
   (`: Animal`) becomes its virtual type (`Animal+`), dispatching at runtime
   to the subclass as before. Not affected: `NoReturn` bodies, and return
   types that aren't value types (`: Array` without type arguments, modules,
   `self` in a module).
3. **Incremental compilation is on**, cached in `CRYSTAL_CACHE_DIR` (default
   `~/.cache/crystal`): `crystal-alpha build` with nothing changed only checks
   file fingerprints and macro inputs. If something looks stale, build with
   `--no-incremental` (or `CRYSTAL_INCREMENTAL=0`) and please report it.
4. **`run` macros must name what they read.** A build that used `{{ run(...) }}`
   is now skipped when nothing changed, judging by the program's sources, the
   arguments that are files or directories, and the files the program lists
   in the file named by the `CRYSTAL_MACRO_RUN_DEPFILE` environment variable
   (one path per line). A `run` program reading other files (a fixed config
   path, a glob of its own) should list them there; or set
   `CRYSTAL_MACRO_RUN_TRUST=0` to never skip such builds. ECR, Slang and
   i18n embeds are covered by their arguments.
5. **`crystal-alpha run` without a file** builds the shard's main file
   (`shard.yml`) and, in a terminal, keeps running and restarting on
   changes; it no longer exits after one run. Scripts and CI (no terminal),
   `crystal-alpha run file.cr` and `crystal-alpha run --no-watch` run once.
6. **`.crystal-watch/`** appears in projects where `crystal-alpha run` or
   `crystal-alpha watch` ran (it holds the build status; it ignores itself in git).
7. **Processes are spawned with `posix_spawn`** on Linux (glibc) instead of
   `fork` + `exec`, when no `chdir:` is given: much faster from a large
   process, same redirections, environment and signal handling. Code that
   relied on running Crystal code in the child between `fork` and `exec`
   can't, but the standard library never offered that for `Process.new`.
8. In strict code, a method with a declared return type always counts as
   possibly raising (calls to it inside `begin`/`rescue` use `invoke`), and a
   body that is just a literal or `self` isn't inlined at its call sites:
   no change in behavior, slightly slower non-release builds. (Release builds
   inline through LLVM as before.)

## Benchmark: an Amber V2 blog

A blog engine on Amber `2.0.0-beta.5` and Grant, with strict signatures
enabled: 12 models with
associations, generated by the Amber CLI (`amber new` and
`amber generate scaffold`: models, controllers, schemas, ECR views),
101 source files. Priit measured how long until the running server showed a
change on his Linux host; these measurements have not been repeated for this
fork's default mode:

| Change | Crystal 1.21.0 | This fork, `crystal-alpha run` | Faster |
|---|---|---|---|
| A model method body | 37.3 s | 1.5 s | 24× |
| A controller action | 36.7 s | 1.9 s | 19× |
| A template (ECR) | 37.1 s | 1.3 s | 28× |
| First build (empty cache) | 57.2 s | 28.2 s | 2× |

`crystal-alpha run` is the everyday loop: started in the project in a terminal,
it rebuilds and restarts the server on every save (`--no-watch` runs
once). For Crystal 1.21.0 it's the `crystal build` time, before restarting
the server (its `crystal run` builds the same way). The fork's
`crystal-alpha build`, without `crystal-alpha run` running, took 18-20 s for these
edits (2× faster) and 0.08 s when nothing changed.

His script checked after each edit that the server served the new code.
Crystal 1.21.0 varied between 48 and 57 s cold and 28 and 40 s per rebuild
over three runs; the fork's times were stable. Tested on Ubuntu 26.04.1
LTS, x86_64 (Linux kernel 7.0.0-31-generic) with LLVM 21.1.8, AMD Ryzen 7
PRO 6850U (8 cores).

The benchmark fixture and scripts were omitted from this port because their
dependency manifest used a mutable version range without a verified hash.

---

# Crystal (upstream README)

[![Linux CI Build Status](https://github.com/crystal-lang/crystal/workflows/Linux%20CI/badge.svg)](https://github.com/crystal-lang/crystal/actions?query=workflow%3A%22Linux+CI%22+event%3Apush+branch%3Amaster)
[![macOS CI Build Status](https://github.com/crystal-lang/crystal/workflows/macOS%20CI/badge.svg)](https://github.com/crystal-lang/crystal/actions?query=workflow%3A%22macOS+CI%22+event%3Apush+branch%3Amaster)
[![AArch64 CI Build Status](https://github.com/crystal-lang/crystal/workflows/AArch64%20CI/badge.svg)](https://github.com/crystal-lang/crystal/actions?query=workflow%3A%22AArch64+CI%22+event%3Apush+branch%3Amaster)
[![Windows CI Build Status](https://github.com/crystal-lang/crystal/workflows/Windows%20CI/badge.svg)](https://github.com/crystal-lang/crystal/actions?query=workflow%3A%22Windows+CI%22+event%3Apush+branch%3Amaster)
[![CircleCI Build Status](https://circleci.com/gh/crystal-lang/crystal/tree/master.svg?style=shield)](https://circleci.com/gh/crystal-lang/crystal)
[![Join the chat at https://gitter.im/crystal-lang/crystal](https://badges.gitter.im/crystal-lang/crystal.svg)](https://gitter.im/crystal-lang/crystal)
[![Code Triagers Badge](https://www.codetriage.com/crystal-lang/crystal/badges/users.svg)](https://www.codetriage.com/crystal-lang/crystal)

---

[![Crystal - Born and raised at Manas](doc/assets/crystal-born-and-raised.svg)](https://manas.tech/)

Crystal is a programming language with the following goals:

- Have a syntax similar to Ruby (but compatibility with it is not a goal)
- Statically type-checked but without having to specify the type of variables or method arguments.
- Be able to call C code by writing bindings to it in Crystal.
- Have compile-time evaluation and generation of code, to avoid boilerplate code.
- Compile to efficient native code.

## Why?

We love Ruby's efficiency for writing code.

We love C's efficiency for running code.

We want the best of both worlds.

We want the compiler to understand what we mean without having to specify types everywhere.

We want full OOP.

Oh, and we don't want to write C code to make the code run faster.

## Project Status

Within a major version, language features won't be removed or changed in any way that could prevent a Crystal program written with that version from compiling and working. The built-in standard library might be enriched, but it will always be done with backwards compatibility in mind.

Development of the Crystal language is possible thanks to the community's effort and the continued support of [84codes](https://www.84codes.com/) and every other [sponsor](https://crystal-lang.org/sponsors).

## Installing

[Follow these installation instructions](https://crystal-lang.org/install)

## Try it online

[play.crystal-lang.org](https://play.crystal-lang.org/)

## Documentation

- [Language Reference](http://crystal-lang.org/reference)
- [Standard library API](https://crystal-lang.org/api)
- [Roadmap](https://github.com/crystal-lang/crystal/wiki/Roadmap)

## Community

Have any questions or suggestions? Ask on the [Crystal Forum](https://forum.crystal-lang.org), on our [Gitter channel](https://gitter.im/crystal-lang/crystal) or IRC channel [#crystal-lang](https://web.libera.chat/#crystal-lang) at irc.libera.chat, or on Stack Overflow under the [crystal-lang](http://stackoverflow.com/questions/tagged/crystal-lang) tag. There is also an archived [Google Group](https://groups.google.com/forum/?fromgroups#!forum/crystal-lang).

## Contributing

The Crystal repository is hosted at [crystal-lang/crystal](https://github.com/crystal-lang/crystal) on GitHub.

Read the general [Contributing guide](https://github.com/crystal-lang/crystal/blob/master/CONTRIBUTING.md), and then:

1. Fork it (<https://github.com/crystal-lang/crystal/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request
