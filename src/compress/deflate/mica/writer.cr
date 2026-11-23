# A write-only `IO` object to compress data in the DEFLATE format.
#
# Instances of this class wrap another IO object. When you write to this
# instance, it compresses the data and writes it to the underlying IO.
#
# NOTE: unless created with a block, `close` must be invoked after all
# data has been written to a Flate::Writer instance.
class Compress::Deflate::Writer < IO
  # The level `DEFAULT_COMPRESSION` stands for, as in zlib.
  private DEFAULT_LEVEL = 6

  # If `#sync_close?` is `true`, closing this IO will close the underlying IO.
  property? sync_close : Bool

  @deflater : Crystal::Mica::Deflate::Writer
  @closed = false

  # Creates an instance of Flate::Writer. `close` must be invoked after all data
  # has written.
  #
  # *strategy* applies to the zlib encoder (`-Duse_libz`) only. With *dict*
  # the stream starts from that preset dictionary, which the reader needs too.
  def initialize(@output : IO, level : Int32 = Compress::Deflate::DEFAULT_COMPRESSION,
                 strategy : Compress::Deflate::Strategy = Compress::Deflate::Strategy::DEFAULT,
                 @sync_close : Bool = false, @dict : Bytes? = nil)
    unless -1 <= level <= 9
      raise ArgumentError.new("Invalid Flate level: #{level} (must be in -1..9)")
    end

    level = DEFAULT_LEVEL if level == Compress::Deflate::DEFAULT_COMPRESSION
    @deflater = Crystal::Mica::Deflate::Writer.new(@output, level: level, dictionary: @dict)
  end

  # Creates a new writer for the given *io*, yields it to the given block,
  # and closes it at its end.
  def self.open(io : IO, level : Int32 = Compress::Deflate::DEFAULT_COMPRESSION,
                strategy : Compress::Deflate::Strategy = Compress::Deflate::Strategy::DEFAULT,
                sync_close : Bool = false, dict : Bytes? = nil, &)
    writer = new(io, level: level, strategy: strategy, sync_close: sync_close, dict: dict)
    yield writer ensure writer.close
  end

  # Always raises `IO::Error` because this is a write-only `IO`.
  def read(slice : Bytes) : NoReturn
    raise "Can't read from Flate::Writer"
  end

  # See `IO#write`.
  def write(slice : Bytes) : Nil
    check_open

    return if slice.empty?

    @deflater.write(slice)
  end

  # Writes everything compressed so far to the underlying IO, ending on a
  # byte boundary (zlib's `Z_SYNC_FLUSH`), and flushes it.
  #
  # See `IO#flush`.
  def flush : Nil
    return if @closed

    @deflater.flush
  end

  # Closes this writer. Must be invoked after all data has been written.
  def close : Nil
    return if @closed
    @closed = true

    @deflater.close

    @output.close if @sync_close
  end

  # Returns `true` if this IO is closed.
  def closed? : Bool
    @closed
  end

  def inspect(io : IO) : Nil
    to_s(io)
  end
end
