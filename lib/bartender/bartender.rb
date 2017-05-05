# -*- coding: utf-8 -*-
require 'socket'
require 'fiber'

module Bartender
  class Context
    def initialize
      @input = {}
      @output = {}
      @alarm = []
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
      @input.empty? && @output.empty? && @alarm.empty?
    end
    
    def step
      r, w = IO.select(@input.keys, @output.keys, [], timeout)
      if r.nil?
        now = Time.now
        expired, @alarm = @alarm.partition {|x| x[0] < now}
        expired.each {|x| x[1].call}
      else
        r.each {|fd| @input[fd].call }
        w.each {|fd| @output[fd].call }
      end
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

    def alarm(time, callback)
      entry = [time, callback]
      @alarm << entry
      @alarm = @alarm.sort_by {|x| x[0]}
      entry
    end

    def delete_alarm(entry)
      @alarm.delete(entry)
    end
    
    def sleep(sec)
      alarm(Time.now + sec, Fiber.current.method(:resume))
      Fiber.yield
    end

    def timeout
      return nil if @alarm.empty?
      [@alarm[0][0] - Time.now, 0].max
    end
    
    def []=(event, fd, callback)
      return delete(event, fd) unless callback
      event_map(event)[fd] = callback
    end

    def delete(event, fd)
      event_map(event).delete(fd)
    end

    def wait_io(event, fd)
      self[event, fd] = Fiber.current.method(:resume)
      Fiber.yield
    ensure
      delete(event, fd)
    end

    def wait_io_timeout(event, fd, timeout)
      method = Fiber.current.method(:resume)
      entry = alarm(Time.now + timeout, Proc.new {method.call(:timeout)})
      self[event, fd] = method
      Fiber.yield
    ensure
      delete(event, fd)
      delete_alarm(entry)
    end

    def wait_readable(fd); wait_io(:read, fd); end
    def wait_writable(fd); wait_io(:write, fd); end

    def _read(fd, sz)
      return fd.read_nonblock(sz)
    rescue IO::WaitReadable
      wait_readable(fd)
      retry
    end

    def _write(fd, buf)
      return fd.write_nonblock(buf)
    rescue IO::WaitWritable
      wait_writable(fd)
      retry
    end
  end

  module_function
  def context
    it = Thread.current.thread_variable_get(:bartender)
    return it if it
    Thread.current.thread_variable_set(:bartender, Context.new)
  end
  def run; context.run; end
  def wait_readable(fd); context.wait_readable(fd); end
  def wait_writable(fd); context.wait_writable(fd); end
  def sleep(sec); context.sleep(sec); end
  def _read(fd, sz); context._read(fd, sz); end
  def _write(fd, buf); context._write(fd, buf); end

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
      @left, @right = IO.pipe
      @task = Thread.new do 
        begin
          block.call(*args)
        ensure
          @left.close
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
end
