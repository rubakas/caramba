# Lists mount points and browses directories on the server host.
#
# Used by the admin panel so an operator can pick media folders from the UI
# instead of typing absolute paths. Directory-only: never returns files,
# never reads file contents. Rejects paths that resolve (via realpath) into
# well-known sensitive areas so a symlink at a benign name can't exfiltrate
# a listing of /etc or /root.

class FilesystemBrowserService
  FORBIDDEN_REAL_PATHS = %w[/etc /System /private/etc /root].freeze

  class InvalidPath < StandardError; end

  class << self
    def list_mounts
      entries = []
      entries << { "name" => "Home", "path" => Dir.home } if Dir.exist?(Dir.home)
      entries << { "name" => "Root", "path" => "/" }

      mount_roots.each do |root|
        next unless Dir.exist?(root)
        Dir.children(root).sort.each do |name|
          full = File.join(root, name)
          next unless File.directory?(full)
          entries << { "name" => name, "path" => full }
        end
      end

      entries.uniq { |e| e["path"] }
    end

    def list_entries(path)
      raise InvalidPath, "path is required" if path.blank?
      raise InvalidPath, "path must be absolute" unless Pathname.new(path).absolute?
      raise InvalidPath, "path does not exist" unless File.exist?(path)
      raise InvalidPath, "path is not a directory" unless File.directory?(path)

      real = safe_realpath(path)
      raise InvalidPath, "path not accessible" unless real
      raise InvalidPath, "path is not permitted" if forbidden?(real)

      children = Dir.children(real).sort_by(&:downcase).filter_map do |name|
        full = File.join(real, name)
        next unless File.directory?(full)
        { "name" => name, "path" => full }
      end

      {
        "path" => real,
        "parent" => parent_of(real),
        "entries" => children
      }
    rescue Errno::EACCES
      raise InvalidPath, "path not readable"
    end

    private

    def mount_roots
      roots = [ "/Volumes" ] # macOS
      roots += [ "/mnt", "/media" ] # Linux
      roots
    end

    def safe_realpath(path)
      File.realpath(path)
    rescue Errno::ENOENT, Errno::EACCES
      nil
    end

    def forbidden?(real_path)
      FORBIDDEN_REAL_PATHS.any? { |prefix| real_path == prefix || real_path.start_with?("#{prefix}/") }
    end

    def parent_of(path)
      return nil if path == "/"
      parent = File.dirname(path)
      parent == path ? nil : parent
    end
  end
end
