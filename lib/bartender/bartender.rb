# -*- coding: utf-8 -*-
require 'bartender/context'

module Bartender
  
  class Writer
    def initialize(fd)
      @bartender = Bartender.context
      @fd = fd
      @pool = []
    end

    def write(buf, buffered=false)
      push(buf)
      flush unless buffered
    end

    def flush
      until @pool.empty?
        len = @bartender._write(@fd, @pool[0])
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
    def initialize(fd)
      @bartender = Bartender.context
      @buf = ''
      @fd = fd
    end

    def read(n)
      while @buf.bytesize < n
        chunk = @bartender._read(@fd, n)
        break if chunk.nil? || chunk.empty?
        @buf += chunk
      end
      @buf.slice!(0, n)
    end

    def read_until(sep="\r\n", chunk_size=8192)
      until (index = @buf.index(sep))
        @buf += @bartender._read(@fd, chunk_size)
      end
      @buf.slice!(0, index+sep.bytesize)
    end

    def readln
      read_until("\n")
    end
  end

  class Server
    def initialize(addr_or_port, port=nil, &blk)
      if port
        address = addr_or_port
      else
        address, port = nil, addr_or_port
      end
      @bartender = Bartender.context
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
      Fiber.new do
        @blk.yield(client)
      end.resume
    end
  end

  class ThreadTask
    def initialize(*args, &block)
      left, @right = IO.pipe
      @task = Thread.new do 
        begin
          block.call(*args)
        ensure
          left.close
        end
      end
    end
    
    def value
      if @right
        Bartender.wait_readable(@right)
        @right.close
      end
      @task.value
    ensure
      @right = nil
    end
  end


  module_function
  def context
    it = Thread.current.thread_variable_get(:bartender)
    return it if it
    Thread.current.thread_variable_set(:bartender, Context.new)
  end

  def self.define_context_method(*list);
    list.each do |m|
      define_method(m) {|*arg| context.send(m, *arg)}
      module_function(m)
    end
  end
  define_context_method(:run, :sleep,
                        :wait_readable, :wait_writable,
                        :_read, :_write)
  def task(&blk)
    ThreadTask.new(&blk)
  end

  def tcp_socket(host, port)
    addr = Socket.sockaddr_in(port, host)
    s = Socket.new(Socket::AF_INET, Socket::SOCK_STREAM, 0)

    begin
      s.connect_nonblock(addr)
    rescue IO::WaitWritable
      wait_writable(s)
      retry
    rescue Errno::EISCONN
      return s
    end
  end
end
