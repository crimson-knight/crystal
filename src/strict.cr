# Requiring this file makes the file that requires it a strict file:
#
# ```
# require "strict"
# ```
#
# A first line that reads `# crystal: strict` does the same without a
# `require`, and `require "strict/project"` does it for every file in the
# directory tree of the file that requires it.
#
# In a strict file:
#
# * every `def` declares the type of each parameter and its return type;
# * a `def` that replaces an earlier definition of the same method, or that
#   overrides an inherited one, is marked `@[Override]`;
# * every `def` that can be is typed once, against the types it declares, as
#   if it were marked `@[TypeOnce]`.
#
# Strict files and ordinary files live in one program and call each other
# freely. The compiler reads the `require` itself; this file is intentionally
# empty, so a compiler without strict files needs only an empty file at this
# path (a shard named `strict`) to build the same code.
