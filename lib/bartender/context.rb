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
      r, w = IO.select(@input.keys, @output.keys, [], next_alarm)
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
      when :read, :wait_readable, IO::WaitReadable
        @input
      when :write, :wait_writable, IO::WaitWritable
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

    def to_time(it)
      return it if it.is_a? Time
      Time.now + it
    end
    
    def sleep(timeout)
      alarm(to_time(timeout), Fiber.current.method(:resume))
      Fiber.yield
    end

    def next_alarm
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

    def wait_io(event, fd, timeout=nil)
      method = Fiber.current.method(:resume)
      if timeout
        time = to_time(timeout)
        entry = alarm(time, Proc.new {method.call(:timeout)})
      end
      self[event, fd] = method
      raise(TimeoutError) if Fiber.yield == :timeout
    ensure
      delete(event, fd)
      delete_alarm(entry) if timeout
    end

    def wait_readable(fd, timeout=nil); wait_io(:read, fd, timeout); end
    def wait_writable(fd, timeout=nil); wait_io(:write, fd, timeout); end

    def _read(fd, sz, timeout=nil)
      return fd.read_nonblock(sz)
    rescue IO::WaitReadable
      wait_readable(fd, timeout)
      retry
    end

    def _write(fd, buf, timeout=nil)
      return fd.write_nonblock(buf)
    rescue IO::WaitWritable
      wait_writable(fd, timeout)
      retry
    end
  end
end
