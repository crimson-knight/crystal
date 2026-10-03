# Crystal Alpha — fast rebuilds fork

A Crystal compiler fork where editing a method rebuilds in a fraction of a
second. On a ~8k line Amber app, a method body or template edit rebuilds in
~0.3s instead of 12s, and a rebuild without changes is skipped (0.07s).

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
  without a build per step (`crystal watch hold`), then gets its errors in
  under a second (`crystal watch build`) instead of waiting for a full
  compile. Explicit signatures tell it what each method returns without
  reading the body.
- **By hand:** keep `crystal run` open in a terminal; save a file and the
  program restarts with the change before you've switched windows. Declared
  return types read as documentation and put type errors where you made them.

Both can work on the same project at once if needed: the agent edits, you keep
`crystal run` open, and it rebuilds once when the agent is done.

## Setup

1. **Install the compiler** (Linux; needs LLVM and the usual Crystal build
   dependencies). From a checkout of this repository:

   ```sh
   make install release=1 interpreter=1 PREFIX=~/.local/opt/crystal-alpha
   ln -sfn ~/.local/opt/crystal-alpha/bin/crystal ~/.local/bin/crystal
   crystal watch --help | grep hold   # this fork is the one on PATH
   ```

   The man page step needs `asciidoctor`; if it fails, the compiler is still
   installed. Keep your upstream `shards` binary (it works with this
   compiler), and if linking programs fails on bundled libraries such as
   `libgc`, copy `lib/` from your upstream Crystal install into the prefix.

2. **Migrate your project** to strict signatures (every `def` declares its
   return type), once:

   ```sh
   crystal tool annotate --dry-run   # the return types it would add
   crystal tool annotate             # add them
   crystal build                     # lists what's left to type by llm or hand
   ```

   Commit first, so the change is easy to review. Not ready? Use
   `--no-strict-signatures` (or `CRYSTAL_STRICT_SIGNATURES=0`) meanwhile.

## Prepare Claude Code (or another agent)

Put these hooks in the project's `.claude/settings.json` (also printed by
`crystal watch hooks`). They hold builds while Claude edits and release them
when it stops, so a multi-file edit is built once:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Edit|Write|MultiEdit|NotebookEdit",
        "hooks": [{ "type": "command", "command": "crystal watch hold claude" }]
      }
    ],
    "Stop": [
      {
        "hooks": [{ "type": "command", "command": "crystal watch release" }]
      }
    ]
  }
}
```

And add this to the project's `CLAUDE.md` (or `AGENTS.md` for other agents):

~~~~markdown
## Crystal toolchain (crystal-alpha fork)
- `crystal watch --help` must list `hold` and `build`; if not, the upstream
  compiler is on PATH: tell the user.
- Every `def` here declares its return type (strict signatures). For a new
  method, write the type yourself; for many, run `crystal tool annotate` and
  type what it lists. Don't use `--no-strict-signatures` to get past errors.
- The user keeps `crystal run` (or `crystal watch`) running. Don't start
  another build or watcher; check with `crystal watch status`.
- After your edits, run `crystal watch build`: it builds what changed
  (usually under a second) and prints the errors; exit 1 = fix them.
  Exit 2 = no watcher: use `crystal build --no-codegen` to type check.
- Without the hooks, run `crystal watch hold claude` before editing.
- Specs: `crystal spec --affected` runs just the examples your edits reach
  (fast with the watcher); run plain `crystal spec` before finishing.
  A single file or example: `crystal spec [spec/file_spec.cr:LINE]`.
- Editing method bodies and adding methods is fastest; changing signatures,
  removing methods or adding types is fine but rebuilds fully (~10s).
- Format: `crystal tool format`.
~~~~

## Usage

In a shard, commands find the main file from `shard.yml` (first target's
`main`, else `src/<name>.cr`):

```sh
crystal run      # build, run, rebuild + restart on every change (in a terminal)
crystal build    # build; skipped if nothing changed
crystal spec     # run the specs; skipped build if nothing changed
```

`crystal run file.cr` runs once as before; `--watch` / `--no-watch` choose.
`crystal watch` rebuilds without running.

While `crystal run` or `crystal watch` is running, the other commands use it:
`crystal build` gets its up to date executable, and `crystal spec` has it keep
the spec program typed too, so after an edit the specs rebuild in about a
second instead of compiling from scratch. Other programs (the hooks above, an
agent, a script) talk to it as well:

```sh
crystal spec --affected     # run only the examples reaching code changed since the last spec run
crystal watch hold claude   # don't build while editing
crystal watch release       # build what changed, once
crystal watch build         # build now, wait, print errors (exit 0 ok, 1 failed, 2 no watcher)
crystal watch status        # result of the last build
```

What rebuilds fast (~0.3s): method bodies, methods added to a class, struct or
module (unless they override another or a macro lists the type's methods),
templates (Slang, ECR) rendered inside a method, and the fix after a type
error. A signature change, a new type, a removed method, or a file read by a
top-level macro (e.g. i18n locales) rebuilds fully (~10s).

## Why strict signatures

Every `def` in your project (not `lib/`, not the standard library) declares
its return type, and that declared type is what callers see. A body edit then
can't change any type elsewhere in the program, so only that method is typed
and code-generated again. Annotated code still compiles with upstream Crystal.

How it works: `IC_PHASE_8_STRICT_SIGNATURES.md`. Incremental caching and
`--no-incremental`: `INCREMENTAL_PLAN.md`.

## What's different from upstream Crystal

> [!WARNING]
> **Strict signatures are a breaking language change for code you compile
> as your own project.** Shards you depend on (in `lib/`) are exempt and
> compile unchanged. But developing a shard, or an app, means annotating it:
> of 43 popular shards whose specs we could compile, 42 had methods without a
> return type (median 17, up to 847), and in 5 (amber, asset_pipeline,
> lucky, shards, vips) existing return types broke callers that relied on
> the narrower inferred type (point 2 below). `crystal tool annotate`
> does most of the first part; the second needs a human (or an agent) to
> make the declared types precise. Use `--no-strict-signatures` for code
> you don't want to migrate.

Things to check when switching a project or system to this compiler:

1. **Strict signatures are on (breaking).** In your project's code (the
   current directory, except `lib/` and anything on `CRYSTAL_PATH`) every
   `def` must declare its return type, or the build fails with a list of the
   methods missing one. Run `crystal tool annotate`, or opt out with
   `--no-strict-signatures` / `CRYSTAL_STRICT_SIGNATURES=0` (e.g. in CI for a
   project not migrated yet). `initialize` and methods generated by macros
   are exempt.
2. **A declared return type is what callers see.** Upstream, `def foo : Int32?`
   whose body returns an `Int32` has type `Int32` at call sites; here it's
   `Int32?`. Code relying on the narrower type (arithmetic on the result,
   `typeof`, an overload only the narrow type matches) fails to compile:
   declare the precise type (`: Int32`) or handle the wider one. A class
   (`: Animal`) becomes its virtual type (`Animal+`), dispatching at runtime
   to the subclass as before. Not affected: `NoReturn` bodies, and return
   types that aren't value types (`: Array` without type arguments, modules,
   `self` in a module).
3. **Incremental compilation is on**, cached in `CRYSTAL_CACHE_DIR` (default
   `~/.cache/crystal`): `crystal build` with nothing changed only checks
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
5. **`crystal run` without a file** builds the shard's main file
   (`shard.yml`) and, in a terminal, keeps running and restarting on
   changes; it no longer exits after one run. Scripts and CI (no terminal),
   `crystal run file.cr` and `crystal run --no-watch` run once.
6. **`.crystal-watch/`** appears in projects where `crystal run` or
   `crystal watch` ran (it holds the build status; it ignores itself in git).
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
