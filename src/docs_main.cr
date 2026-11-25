# This is the main file used for generating docs for the standard library.
# It, for example, doesn't include API for the compiler, but does include
# the fictitious API for the Crystal::Macros module.

require "./annotations"
require "./compiler/crystal/macros"

require "./*"
require "./big/**"
# Compress::Deflate has two backends (compress/deflate/lib_z and
# compress/deflate/mica) that define the same classes; the entry files choose
# one with `flag?(:use_libz)`, so the docs load them rather than a `**` glob.
require "./compress/deflate"
require "./compress/gzip"
require "./compress/zlib"
require "./compress/zip"
require "./crypto/**"
require "./crystal/syntax_highlighter/*"
require "./digest/**"
require "./fiber/**"
require "./gc/**"
require "./http/**"
require "./io/**"
require "./log/**"
require "./math/**"
require "./random/**"
require "./spec/helpers/**"
require "./string/**"
require "./sync/**"
require "./system/**"
require "./uri/**"
require "./uuid/**"
