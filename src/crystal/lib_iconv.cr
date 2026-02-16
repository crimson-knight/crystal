require "c/stddef"

{% if flag?(:without_iconv) %}
  {% raise "The `without_iconv` flag is preventing you to use the LibIconv module" %}
{% end %}

# Supported library versions:
#
# * libiconv-gnu
# * POSIX iconv (musl/wasi-libc on wasm32)
#
# See https://crystal-lang.org/reference/man/required_libraries.html#internationalization-conversion
@[Link("iconv")]
{% if compare_versions(Crystal::VERSION, "1.11.0-dev") >= 0 %}
  @[Link(dll: "iconv-2.dll")]
{% end %}
lib LibIconv
  type IconvT = Void*

  alias Int = LibC::Int
  alias Char = LibC::Char
  alias SizeT = LibC::SizeT

  {% if flag?(:wasm32) %}
    # wasi-libc (musl-based) uses POSIX iconv symbol names
    fun iconv(cd : IconvT, inbuf : Char**, inbytesleft : SizeT*, outbuf : Char**, outbytesleft : SizeT*) : SizeT
    fun iconv_close(cd : IconvT) : Int
    fun iconv_open(tocode : Char*, fromcode : Char*) : IconvT
  {% else %}
    # GNU libiconv uses "lib"-prefixed symbol names
    fun iconv = libiconv(cd : IconvT, inbuf : Char**, inbytesleft : SizeT*, outbuf : Char**, outbytesleft : SizeT*) : SizeT
    fun iconv_close = libiconv_close(cd : IconvT) : Int
    fun iconv_open = libiconv_open(tocode : Char*, fromcode : Char*) : IconvT
  {% end %}
end
