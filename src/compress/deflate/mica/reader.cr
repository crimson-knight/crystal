# A read-only `IO` object to decompress data in the DEFLATE format.
#
# Instances of this class wrap another IO object. When you read from this instance
# instance, it reads data from the underlying IO, decompresses it, and returns
# it to the caller.
#
# The reader takes from the underlying IO only the bytes of the DEFLATE
# stream (through `IO#peek` when the IO has it, a byte at a time otherwise),
# so whatever follows the stream, such as a gzip trailer or the next entry of
# a zip file, can still be read from it.
class Compress::Deflate::Reader < IO
  include IO::Buffered

  # The decoder's limits: none beyond DEFLATE's own. Any output size, the full
  # 32 KiB window, and no work budget. DEFLATE cannot expand its input more
  # than about 1,032 times, so the ratio check never stops a valid stream.
  private LIMITS = Crystal::Mica::Deflate::DecodeLimits.new(
    max_output_bytes: Int64::MAX,
    max_ratio: 1_100_i64,
    max_window_bytes: Crystal::Mica::Deflate::DecodeLimits::MAX_WINDOW_BYTES,
    max_members: 1,
    max_metadata_bytes: 0,
    work_per_unit: 0_i64,
    base_work: Int64::MAX,
  )

  # If `#sync_close?` is `true`, closing this IO will close the underlying IO.
  property? sync_close : Bool

  # Returns `true` if this reader is closed.
  getter? closed = false

  # Dictionary passed in the constructor
  getter dict : Bytes?

  @inflater : Crystal::Mica::Deflate::Reader

  # Creates an instance of Flate::Reader.
  def initialize(@io : IO, @sync_close : Bool = false, @dict : Bytes? = nil)
    @inflater = Crystal::Mica::Deflate::Reader.new(@io, limits: LIMITS, timeout: nil, dictionary: @dict, stop_at_end: true)
  end

  # Creates a new reader from the given *io*, yields it to the given block,
  # and closes it at its end.
  def self.open(io : IO, sync_close : Bool = false, dict : Bytes? = nil, &)
    reader = new(io, sync_close: sync_close, dict: dict)
    yield reader ensure reader.close
  end

  # Always raises `IO::Error` because this is a read-only `IO`.
  def unbuffered_write(slice : Bytes) : NoReturn
    raise IO::Error.new "Can't write to Compress::Deflate::Reader"
  end

  # See `IO#read`.
  def unbuffered_read(slice : Bytes) : Int32
    check_open

    return 0 if slice.empty?

    begin
      @inflater.read(slice)
    rescue error : Crystal::Mica::Error
      raise Compress::Deflate::Error.new("deflate: #{error.message}", cause: error)
    end
  end

  def unbuffered_flush : NoReturn
    raise IO::Error.new "Can't flush Compress::Deflate::Reader"
  end

  # Closes this reader.
  def unbuffered_close : Nil
    return if @closed
    @closed = true

    @inflater.close
    @io.close if @sync_close
  end

  def unbuffered_rewind : Nil
    check_open

    @inflater.close
    @io.rewind

    initialize(@io, @sync_close, @dict)
  end

  def inspect(io : IO) : Nil
    to_s(io)
  end
end
