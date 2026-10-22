# frozen_string_literal: true

require "digest"

# Finds a file in an ImagePath's directory whose content equals an upload's.
#
# Nothing stores a checksum today, so existing files are hashed on demand.
# Only files of exactly the upload's byte size are read: sizes come from one
# stat per entry, so a folder is not read in full for every request.
class FolderDuplicateFinder
  def self.digest(file)
    Digest::SHA256.file(file.path).hexdigest
  end

  def initialize(image_path)
    @directory = image_path.directory_path
    @digests = {}
  end

  # Name of an existing file with this SHA-256 hex digest and size, or nil.
  def existing_name(digest, size)
    names_by_size.fetch(size, []).find { |name| digest_of(name) == digest }
  end

  private

    attr_reader :directory

    # Same entries a scan would index: supported extension, regular file, not a symlink.
    def names_by_size
      @names_by_size ||= Dir.children(directory).each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |name, groups|
        next unless ImageUploadService::ALLOWED_EXTENSIONS.include?(File.extname(name).downcase)

        stat = File.lstat(File.join(directory, name))
        groups[stat.size] << name if stat.file?
      rescue SystemCallError
        next
      end
    end

    def digest_of(name)
      @digests[name] ||= Digest::SHA256.file(File.join(directory, name)).hexdigest
    rescue SystemCallError
      @digests[name] = nil
    end
end
