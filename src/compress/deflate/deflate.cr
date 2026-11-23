{% if flag?(:use_libz) %}
  require "lib_z"
{% else %}
  require "crystal/mica/deflate"
{% end %}
require "./*"

# The Deflate module contains readers and writers of DEFLATE format compressed
# data, as specified in [RFC 1951](https://www.ietf.org/rfc/rfc1951.txt).
#
# See `Gzip`, `Zip` and `Zlib` for modules that provide access
# to DEFLATE-based file formats.
#
# The readers and writers run on Mica's DEFLATE, written in Crystal, so a
# program that uses them links no libz. Build with `-Duse_libz` to run them
# on zlib instead (see `doc/compress_mica.md`).
#
# NOTE: To use `Deflate` or its children, you must explicitly import it with `require "compress/deflate"`
module Compress::Deflate
  NO_COMPRESSION      =  0
  BEST_SPEED          =  1
  BEST_COMPRESSION    =  9
  DEFAULT_COMPRESSION = -1

  # How the zlib encoder (`-Duse_libz`) chooses matches. Mica's encoder has
  # one strategy and ignores this setting.
  enum Strategy
    FILTERED     = 1
    HUFFMAN_ONLY = 2
    RLE          = 3
    FIXED        = 4
    DEFAULT      = 0
  end

  class Error < Exception
    {% if flag?(:use_libz) %}
      def initialize(ret, stream)
        msg = stream.msg
        msg = LibZ.zError(ret) if msg.null?

        if msg
          error_msg = String.new(msg)
          super("deflate: #{error_msg}")
        else
          super("deflate: #{ret}")
        end
      end
    {% end %}
  end
end
