module Crystal
  module Watch
    # Abstract base class for file watching implementations.
    #
    # Subclasses implement platform-specific file watching (kqueue, inotify)
    # or a portable polling fallback.
    abstract class FileWatcher
      # Register a set of files to watch for changes.
      # Replaces any previously watched file set.
      abstract def watch(files : Set(String)) : Nil

      # Block until at least one watched file changes.
      # Returns the list of changed file paths after debouncing.
      abstract def wait_for_changes(debounce : Time::Span) : Array(String)

      # Release all resources (file descriptors, etc).
      abstract def close : Nil

      # Factory method: returns the best available FileWatcher for the platform.
      def self.create(force_polling : Bool = false, poll_interval : Time::Span = 1.second) : FileWatcher
        if force_polling
          return Polling.new(poll_interval)
        end

        {% if flag?(:darwin) || flag?(:freebsd) || flag?(:openbsd) %}
          KqueueWatcher.new
        {% elsif flag?(:linux) %}
          InotifyWatcher.new
        {% else %}
          Polling.new(poll_interval)
        {% end %}
      end
    end

    # Portable file watcher that uses mtime polling.
    # Works on all platforms but has higher latency than native watchers.
    class Polling < FileWatcher
      @mtimes : Hash(String, Int64) = {} of String => Int64
      @poll_interval : Time::Span

      def initialize(@poll_interval : Time::Span = 1.second)
      end

      def watch(files : Set(String)) : Nil
        new_mtimes = {} of String => Int64
        files.each do |path|
          if info = File.info?(path)
            new_mtimes[path] = info.modification_time.to_unix
          end
        end
        @mtimes = new_mtimes
      end

      def wait_for_changes(debounce : Time::Span) : Array(String)
        loop do
          sleep @poll_interval

          changed = [] of String
          @mtimes.each do |path, old_mtime|
            if info = File.info?(path)
              current_mtime = info.modification_time.to_unix
              if current_mtime != old_mtime
                changed << path
                @mtimes[path] = current_mtime
              end
            else
              # File was deleted
              changed << path
            end
          end

          unless changed.empty?
            # Debounce: wait a bit then collect any additional changes
            sleep debounce
            @mtimes.each do |path, old_mtime|
              next if changed.includes?(path)
              if info = File.info?(path)
                current_mtime = info.modification_time.to_unix
                if current_mtime != old_mtime
                  changed << path
                  @mtimes[path] = current_mtime
                end
              else
                changed << path
              end
            end
            return changed
          end
        end
      end

      def close : Nil
        @mtimes.clear
      end
    end
  end
end
