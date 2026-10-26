# frozen_string_literal: true

require "socket"

# A real HTTP server on 127.0.0.1, on a free port, in a thread: for tests of
# what Net::HTTP actually sends and how the transport reads what comes back,
# which a fake transport can't show. Each request is read, kept in
# `requests`, and handed to the handler with its connection, which writes the
# reply's bytes itself, so it can trickle, stall or break HTTP on purpose.
#
#   LocalServer.open(->(request, socket) { LocalServer.reply(socket, 200, "ok") }) do |server|
#     Net::HTTP.get(URI(server.url("/")))
#   end
class LocalServer
  # `chunked` is whether the body came with Transfer-Encoding: chunked.
  Request = Struct.new(:method, :path, :headers, :body, :chunked) # rubocop:disable Lint/StructNewOverride

  def self.open(handler)
    server = new(handler)
    yield server
  ensure
    server&.close
  end

  # Writes a whole reply; the connection closes after it.
  def self.reply(socket, status, body = "", headers = {})
    head = { "Content-Length" => body.bytesize, "Connection" => "close" }.merge(headers)
    socket.write("HTTP/1.1 #{status} Status\r\n", *head.map { |name, value| "#{name}: #{value}\r\n" },
                 "\r\n", body)
  end

  def initialize(handler)
    @handler = handler
    @requests = []
    @connections = 0
    @lock = Mutex.new
    @listener = TCPServer.new("127.0.0.1", 0)
    @threads = [Thread.new { serve }]
  end

  # The requests read so far.
  def requests = @lock.synchronize { @requests.dup }

  # The connections opened so far, also ones whose request never arrived whole.
  def connections = @lock.synchronize { @connections }

  def url(path) = "http://127.0.0.1:#{@listener.addr[1]}#{path}"

  # Stops it, handlers still stalling too.
  def close
    @threads.first.kill.join # no more threads after it
    @threads.each(&:kill).each(&:join)
    @listener.close
  end

  private

  # Each connection in a thread of its own, so a stalling handler doesn't
  # hold up the next attempt.
  def serve
    loop do
      socket = @listener.accept
      @lock.synchronize { @connections += 1 }
      @threads << Thread.new { handle(socket) }
    end
  end

  def handle(socket)
    request = read(socket)
    @lock.synchronize { @requests << request }
    @handler.call(request, socket)
  rescue IOError, SystemCallError
    nil # the client gave up (a timeout)
  ensure
    socket.close
  end

  def read(socket)
    method, path = socket.gets("\r\n").split
    headers = {}
    while (line = socket.gets("\r\n")) && line != "\r\n"
      name, value = line.split(":", 2)
      headers[name.downcase] = value.strip
    end
    chunked = headers["transfer-encoding"].to_s.include?("chunked")
    body = chunked ? read_chunks(socket) : socket.read(headers["content-length"].to_i)
    Request.new(method, path, headers, body, chunked)
  end

  def read_chunks(socket)
    body = +""
    while (size = socket.gets("\r\n").to_i(16)).positive?
      body << socket.read(size)
      socket.gets("\r\n")
    end
    socket.gets("\r\n")
    body
  end
end
