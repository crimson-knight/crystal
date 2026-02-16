{% if flag?(:linux) %}
  lib LibInotify
    fun inotify_init1(flags : LibC::Int) : LibC::Int
    fun inotify_add_watch(fd : LibC::Int, pathname : LibC::Char*, mask : UInt32) : LibC::Int
    fun inotify_rm_watch(fd : LibC::Int, wd : LibC::Int) : LibC::Int
  end

  module Crystal
    module Watch
      # inotify event masks
      IN_MODIFY      = 0x00000002_u32
      IN_CLOSE_WRITE = 0x00000008_u32
      IN_CREATE      = 0x00000100_u32
      IN_DELETE      = 0x00000200_u32
      IN_MOVED_FROM  = 0x00000040_u32
      IN_MOVED_TO    = 0x00000080_u32
      IN_NONBLOCK    =           2048 # O_NONBLOCK

      # Size of the inotify_event struct header (without the name field)
      # struct inotify_event { int wd; uint32_t mask; uint32_t cookie; uint32_t len; char name[]; }
      INOTIFY_EVENT_SIZE = 16

      # Native file watcher for Linux using inotify.
      #
      # Watches directories containing the target files rather than individual
      # files, which is more efficient and avoids hitting inotify watch limits.
      # Events are filtered to only report changes to files in the watched set.
      class InotifyWatcher < FileWatcher
        # The inotify file descriptor
        @inotify_fd : Int32
        # IO wrapper for blocking reads
        @inotify_io : IO::FileDescriptor
        # Maps directory path -> watch descriptor
        @dir_watches : Hash(String, Int32) = {} of String => Int32
        # Maps watch descriptor -> directory path
        @wd_to_dir : Hash(Int32, String) = {} of Int32 => String
        # Set of watched file paths (absolute)
        @watched_files : Set(String) = Set(String).new

        def initialize
          @inotify_fd = LibInotify.inotify_init1(IN_NONBLOCK)
          if @inotify_fd == -1
            raise RuntimeError.from_errno("inotify_init1")
          end
          @inotify_io = IO::FileDescriptor.new(@inotify_fd, blocking: false)
        end

        def watch(files : Set(String)) : Nil
          @watched_files = files.dup

          # Compute directories that need watching
          needed_dirs = Set(String).new
          files.each do |path|
            needed_dirs << File.dirname(path)
          end

          current_dirs = @dir_watches.keys.to_set

          # Remove directories no longer needed
          (current_dirs - needed_dirs).each do |dir|
            if wd = @dir_watches.delete(dir)
              @wd_to_dir.delete(wd)
              LibInotify.inotify_rm_watch(@inotify_fd, wd)
            end
          end

          # Add newly needed directories
          mask = IN_MODIFY | IN_CLOSE_WRITE | IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO

          (needed_dirs - current_dirs).each do |dir|
            wd = LibInotify.inotify_add_watch(@inotify_fd, dir.check_no_null_byte, mask)
            if wd == -1
              STDERR.puts "[watch] Warning: cannot watch directory '#{dir}': #{Errno.value.message}"
              next
            end
            @dir_watches[dir] = wd
            @wd_to_dir[wd] = dir
          end
        end

        def wait_for_changes(debounce : Time::Span) : Array(String)
          changed = Set(String).new
          buf = Bytes.new(4096)

          # Poll for events with a 1-second sleep between attempts
          loop do
            begin
              @inotify_io.wait_readable(timeout: 1.second)
            rescue IO::TimeoutError
              next
            end

            bytes_read = LibC.read(@inotify_fd, buf.to_unsafe, buf.size)
            next if bytes_read <= 0

            parse_inotify_events(buf, bytes_read.to_i, changed)
            break unless changed.empty?
          end

          # Debounce: wait then drain additional events
          unless debounce.zero?
            sleep debounce

            loop do
              bytes_read = LibC.read(@inotify_fd, buf.to_unsafe, buf.size)
              break if bytes_read <= 0
              parse_inotify_events(buf, bytes_read.to_i, changed)
            end
          end

          changed.to_a
        end

        def close : Nil
          @dir_watches.each_value do |wd|
            LibInotify.inotify_rm_watch(@inotify_fd, wd)
          end
          @dir_watches.clear
          @wd_to_dir.clear
          @watched_files.clear
          @inotify_io.close
        end

        private def parse_inotify_events(buf : Bytes, bytes_read : Int32, changed : Set(String)) : Nil
          offset = 0
          while offset + INOTIFY_EVENT_SIZE <= bytes_read
            # Read fields from the inotify_event struct
            wd = IO::ByteFormat::SystemEndian.decode(Int32, buf[offset, 4])
            name_len = IO::ByteFormat::SystemEndian.decode(UInt32, buf[offset + 12, 4])
            event_size = INOTIFY_EVENT_SIZE + name_len.to_i

            break if offset + event_size > bytes_read

            if name_len > 0 && (dir = @wd_to_dir[wd]?)
              # Extract filename (null-terminated within name_len bytes)
              name_start = offset + INOTIFY_EVENT_SIZE
              name_bytes = buf[name_start, name_len]
              null_idx = name_bytes.index(0_u8) || name_len.to_i
              name = String.new(name_bytes[0, null_idx])
              full_path = File.join(dir, name)

              if @watched_files.includes?(full_path)
                changed << full_path
              end
            end

            offset += event_size
          end
        end
      end
    end
  end
{% end %}
