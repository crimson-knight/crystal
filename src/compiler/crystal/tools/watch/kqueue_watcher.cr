{% if flag?(:darwin) || flag?(:freebsd) || flag?(:openbsd) %}
  require "c/fcntl"
  require "c/sys/event"

  module Crystal
    module Watch
      # Native file watcher for macOS/BSD using kqueue and EVFILT_VNODE.
      #
      # Watches individual files by opening read-only file descriptors and
      # registering them with kqueue for vnode events (write, delete, rename, etc).
      class KqueueWatcher < FileWatcher
        # Maps file path -> open file descriptor
        @watched_fds : Hash(String, Int32) = {} of String => Int32
        # Maps file descriptor -> file path (reverse lookup)
        @fd_to_path : Hash(Int32, String) = {} of Int32 => String
        @kq : Int32

        def initialize
          @kq = LibC.kqueue
          if @kq == -1
            raise RuntimeError.from_errno("kqueue")
          end
        end

        def watch(files : Set(String)) : Nil
          new_paths = files
          old_paths = @watched_fds.keys.to_set

          # Remove files no longer in the set
          (old_paths - new_paths).each do |path|
            remove_watch(path)
          end

          # Add newly required files
          (new_paths - old_paths).each do |path|
            add_watch(path)
          end
        end

        def wait_for_changes(debounce : Time::Span) : Array(String)
          buffer = uninitialized LibC::Kevent[32]
          events = buffer.to_slice
          changed = Set(String).new

          # Block indefinitely for the first event
          count = LibC.kevent(@kq, nil, 0, events.to_unsafe, events.size, nil)
          if count == -1
            if Errno.value == Errno::EINTR
              return [] of String
            end
            raise RuntimeError.from_errno("kevent wait")
          end

          count.times do |i|
            fd = events[i].ident.to_i32
            if path = @fd_to_path[fd]?
              changed << path
            end
          end

          # Debounce: drain additional events within the debounce window
          unless debounce.zero?
            sleep debounce

            ts = uninitialized LibC::Timespec
            ts.tv_sec = typeof(ts.tv_sec).new!(0)
            ts.tv_nsec = typeof(ts.tv_nsec).new!(0)

            loop do
              count = LibC.kevent(@kq, nil, 0, events.to_unsafe, events.size, pointerof(ts))
              break if count <= 0

              count.times do |i|
                fd = events[i].ident.to_i32
                if path = @fd_to_path[fd]?
                  changed << path
                end
              end

              break if count < events.size
            end
          end

          # Re-open watches for deleted/renamed files (they may have been recreated)
          changed.each do |path|
            if @watched_fds.has_key?(path)
              remove_watch(path)
              add_watch(path) if File.exists?(path)
            end
          end

          changed.to_a
        end

        def close : Nil
          @watched_fds.each_value do |fd|
            LibC.close(fd)
          end
          @watched_fds.clear
          @fd_to_path.clear
          LibC.close(@kq)
        end

        private def add_watch(path : String) : Nil
          fd = LibC.open(path.check_no_null_byte, LibC::O_RDONLY)
          if fd == -1
            STDERR.puts "[watch] Warning: cannot watch '#{path}': #{Errno.value.message}"
            STDERR.puts "[watch] If you hit the file descriptor limit, try: ulimit -n 4096"
            return
          end

          @watched_fds[path] = fd
          @fd_to_path[fd] = path

          fflags = LibC::NOTE_WRITE | LibC::NOTE_DELETE | LibC::NOTE_RENAME | LibC::NOTE_ATTRIB

          kevent = uninitialized LibC::Kevent
          kevent.ident = LibC::SizeT.new!(fd)
          kevent.filter = LibC::EVFILT_VNODE
          kevent.flags = LibC::EV_ADD | LibC::EV_CLEAR
          kevent.fflags = fflags
          kevent.data = 0
          kevent.udata = Pointer(Void).null

          ret = LibC.kevent(@kq, pointerof(kevent), 1, nil, 0, nil)
          if ret == -1
            STDERR.puts "[watch] Warning: failed to register kqueue watch for '#{path}': #{Errno.value.message}"
            LibC.close(fd)
            @watched_fds.delete(path)
            @fd_to_path.delete(fd)
          end
        end

        private def remove_watch(path : String) : Nil
          if fd = @watched_fds.delete(path)
            @fd_to_path.delete(fd)
            LibC.close(fd)
          end
        end
      end
    end
  end
{% end %}
