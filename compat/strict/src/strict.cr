# The `strict` shard: what a strict Crystal file needs to build on a compiler
# without strict files.
#
# A compiler with strict files reads `require "strict"`, the first line
# `# crystal: strict` and the three annotations itself. Every other compiler
# needs only the names to exist, and this file declares them:
#
# ```
# require "strict"
#
# class Greeter
#   @[Override]
#   def to_s(io : IO) : Nil
#     io << "hello"
#   end
# end
# ```

# Marks a `def` that replaces an earlier definition of the same method in the
# same type, or overrides a method the type inherits.
annotation Override
end

# Types a method once, against the types its signature declares.
annotation TypeOnce
end

# Declares the bound of a type parameter of a generic class (`@[TypeBound(Model, Record)]`).
annotation TypeBound
end
