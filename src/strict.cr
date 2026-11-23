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
# * a `def` with the same name and argument types as an earlier definition
#   in the same type, or as an inherited method, is marked `@[Override]`.
#   Leaving the mark out is an error. Every method follows the rule
#   (`initialize`, `to_s`, `==`, `hash`, the implementation of an
#   `abstract def`). A `def` with the same name and different argument types
#   is a new overload and needs no mark;
# * a `def` that states the type of every parameter, of its block parameter
#   (`&block : String -> String`, or a proc type named through an `alias`)
#   and of its return value is typed once, against those types, as if it
#   were marked `@[TypeOnce]`;
# * a `def` that leaves one of those types out, or that can't be typed once
#   (it yields, collects a splat, has free variables, or has macro expressions
#   that read `@type`),
#   compiles as in an ordinary file and gets a warning that names the method
#   and what to write.
#
# Strict files and ordinary files live in one program and call each other
# freely. The compiler reads the `require` itself; this file is intentionally
# empty. A compiler without strict files builds the same code with the
# `strict` shard (`compat/strict` in the compiler's repository), which
# declares the three annotations at this path.
