# -*- coding: utf-8 -*-
require 'socket'
require 'fiber'

module Bartender
  class App
    def initialize
      @input = {}
      @output = {}
      @running = false
    end

    def run
      @running = true
      while @running
        step
        break if empty?
      end
    end

    def stop
      @running = false
    end

    def empty?
      @input.empty? && @output.empty?
    end
    
    def step(timeout=nil)
      r, w = IO.select(@input.keys, @output.keys, [], timeout)
      r.each {|fd| @input[fd].call }
      w.each {|fd| @output[fd].call }
    end

    def event_map(event)
      case event
      when :read
        @input
      when :write
        @output
      else
        raise 'invalid event'
      end
    end

    def []=(event, fd, callback)
      return delete(event, fd) unless callback
      event_map(event)[fd] = callback
    end

    def delete(event, fd)
      event_map(event).delete(fd)
    end
  end

  @app = App.new
  module_function
  def primary; @app; end

  class Writer
    def initialize(bartender, fd)
      @bartender = bartender
      @fd = fd
      @pool = []
    end

    def select_writable
      @bartender[:write, @fd] = Fiber.current.method(:resume)
      Fiber.yield
    ensure
      @bartender.delete(:write, @fd)
    end

    def _write(buf)
      return @fd.write_nonblock(buf)
    rescue IO::WaitWritable
      select_writable
      retry
    end

    def write(buf)
      push(buf)
      until @pool.empty?
        len = _write(@pool[0])
        pop(len)
      end
    end

    private
    def push(string)
      return if string.bytesize == 0
      @pool << string
    end
    
    def pop(size)
      return if size < 0 
      raise if @pool[0].bytesize < size
      
      if @pool[0].bytesize == size
        @pool.shift
      else
        unless @pool[0].encoding == Encoding::BINARY
          @pool[0] = @pool[0].dup.force_encoding(Encoding::BINARY)
        end
        @pool[0].slice!(0...size)
      end
    end
  end

  class Reader
    def initialize(bartender, fd)
      @bartender = bartender
      @buf = ''
      @fd = fd
    end

    def read(n)
      while @buf.bytesize < n
        chunk = _read(n)
        break if chunk.nil? || chunk.empty?
        @buf += chunk
      end
      @buf.slice!(0, n)
    end

    def read_until(sep="\r\n", chunk_size=8192)
      until (index = @buf.index(sep))
        @buf += _read(chunk_size)
      end
      @buf.slice!(0, index+sep.bytesize)
    end

    def readln
      read_until("\n")
    end

    private
    def _read(n)
      @fd.read_nonblock(n)
    rescue IO::WaitReadable
      select_readable
      retry
    end
    
    def select_readable
      @bartender[:read, @fd] = Fiber.current.method(:resume)
      Fiber.yield
    ensure
      @bartender.delete(:read, @fd)
    end
  end

  class Server
    def initialize(bartender, addr_or_port, port=nil, &blk)
      if port
        address = addr_or_port
      else
        address, port = nil, addr_or_port
      end
      @bartender = bartender
      create_listeners(address, port).each do |soc|
        @bartender[:read, soc] = Proc.new do
          client = soc.accept
          on_accept(client)
        end
      end
      @blk = blk
    end

    def create_listeners(address, port)
      unless port
        raise ArgumentError, "must specify port"
      end
      sockets = Socket.tcp_server_sockets(address, port)
      sockets = sockets.map {|s|
        s.autoclose = false
        ts = TCPServer.for_fd(s.fileno)
        s.close
        ts
      }
      return sockets
    end

    def on_accept(client)
      reader = Reader.new(@bartender, client)
      writer = Writer.new(@bartender, client)
      Fiber.new do
        @blk.yield(reader, writer)
      end.resume
    end
  end
end
