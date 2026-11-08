# frozen_string_literal: true

require "pathname"

module Nohead
  # Reading files for assets.upload: a path (String or Pathname) or an IO
  # opened in binary mode (File, StringIO).
  class UploadSource
    attr_reader :filename, :content_type, :byte_size, :io

    def initialize(file, filename: nil, content_type: nil, byte_size: nil)
      name, size = file.is_a?(String) || file.is_a?(Pathname) ? open_path(Pathname(file)) : open_io(file)
      # An empty filename or content type is the same as none.
      @filename = present(filename) || present(name) || "upload"
      @byte_size = byte_size || size or
        raise UploadError, "Uploading a stream that cannot seek needs byte_size:"
      # Without one, the API types the file by its filename, as for every client.
      @content_type = present(content_type)
      @start = position(@io)
    end

    # Whether the bytes can be sent again (for retries): a pipe or socket
    # can't seek back to where they start.
    def replayable? = !@start.nil? && @io.respond_to?(:pos=)

    def rewind
      @io.pos = @start if replayable?
    end

    def close
      @io.close if @owned
    end

    private

    def present(value)
      value unless value.to_s.empty?
    end

    def open_path(path)
      @io = path.open("rb")
      @owned = true
      [path.basename.to_s, path.size]
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
      return io.size - io.pos if io.respond_to?(:size) && io.respond_to?(:pos)

      nil
    rescue IOError, SystemCallError
      nil
    end
  end
end
