require 'socket'
require 'fiber'

module Bartender
  class TimeoutError < RuntimeError; end
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
      raise(TimeoutError) if Fiber.yield == :timeout
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

  def self.define_context_method(*list);
    list.each do |m|
      define_method(m) {|*arg| context.send(m, *arg)}
      module_function(m)
    end
  end
  define_context_method(:run, :sleep,
                        :wait_readable, :wait_writable,
                        :_read, :_write)
end
