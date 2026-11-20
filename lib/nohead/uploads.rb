# frozen_string_literal: true

require "pathname"

module Nohead
  # Reading files for assets.upload: a path (String or Pathname) or an IO
  # opened in binary mode (File, StringIO).
  class UploadSource
    attr_reader :filename, :content_type, :byte_size

    def initialize(file, filename: nil, content_type: nil, byte_size: nil)
      name, size = if file.is_a?(String) || file.is_a?(Pathname)
                     open_path(Pathname(file), byte_size)
                   else
                     open_io(file)
                   end
      # An empty filename or content type is the same as none.
      @filename = present(filename) || present(name) || "upload"
      @byte_size = byte_size || size or
        raise UploadError, "Uploading a stream that isn't a file needs byte_size:"
      if size && size < @byte_size
        close
        raise too_short(size)
      end
      # Without one, the API types the file by its filename, as for every client.
      @content_type = present(content_type)
      @start = position(@io)
      @left = @byte_size
    end

    # The bytes for the transport, as IO#read reads them: the first
    # byte_size, the length the upload declared. Raises UploadError when the
    # file ends sooner.
    def read(length = nil, buffer = nil)
      if @left.zero?
        buffer&.clear
        return length ? nil : buffer || +""
      end

      chunk = @io.read(length ? [length, @left].min : @left, buffer)
      size = chunk.to_s.bytesize
      raise too_short(byte_size - @left + size) if chunk.nil? || (length.nil? && size < @left)

      @left -= size
      chunk
    end

    # As IO#readpartial: what the file has ready, so a pipe streams as it
    # fills (IO.copy_stream, and so Net::HTTP, reads with it), up to
    # byte_size in all.
    def readpartial(length, buffer = nil)
      return read(length, buffer) || raise(EOFError) unless @io.respond_to?(:readpartial)
      raise EOFError if @left.zero?

      chunk = @io.readpartial([length, @left].min, buffer)
      @left -= chunk.bytesize
      chunk
    rescue EOFError
      raise too_short(byte_size - @left) unless @left.zero?

      raise
    end

    # Whether the bytes can be sent again (for retries): a pipe or socket
    # can't seek back to where they start.
    def replayable? = !@start.nil? && @io.respond_to?(:pos=)

    # The length a transport sends, as IO#size.
    alias size byte_size

    # Raises Errno::ESPIPE, as a pipe's rewind does, for bytes that can't be
    # sent again.
    def rewind
      raise Errno::ESPIPE, filename unless replayable?

      @io.pos = @start
      @left = @byte_size
    end

    def close
      @io.close if @owned
    end

    private

    def too_short(size)
      UploadError.new("Could not upload #{filename}: it has #{size} bytes, fewer than its byte_size (#{byte_size})")
    end

    def present(value)
      value unless value.to_s.empty?
    end

    def open_path(path, byte_size)
      stat = path.stat # a missing path raises Errno::ENOENT, as opening it would
      raise Errno::EISDIR, path.to_s if stat.directory?

      # A pipe's or a device's size (/dev/stdin) is not what it holds.
      size = stat.size if stat.file?
      raise UploadError, "Uploading #{path.basename}, which is not a file, needs byte_size:" unless size || byte_size

      @io = path.open("rb")
      @owned = true
      [path.basename.to_s, size]
    end

    def open_io(io)
      raise ArgumentError, "Upload a path or an IO; wrap bytes in StringIO.new(bytes)" unless io.respond_to?(:read)

      @io = io
      name = File.basename(io.path) if io.respond_to?(:path) && io.path
      [name, remaining(io)]
    end

    def position(io)
      io.pos if io.respond_to?(:pos)
    rescue IOError, SystemCallError
      nil
    end

    def remaining(io)
      # A device's size (File.open("/dev/stdin")) is not what it holds.
      return nil if io.respond_to?(:stat) && !io.stat.file?
      return io.size - io.pos if io.respond_to?(:size) && io.respond_to?(:pos)

      nil
    rescue IOError, SystemCallError
      nil
    end
  end
end
