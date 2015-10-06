require 'bartender/bartender'

class Rdv
  def initialize
    @reader = []
    @queue = []
  end

  def push(it)
    if @reader.empty?
      @queue << [it, Fiber.current]
      return Fiber.yield
    end

    @reader.shift.resume(it)
  end

  def pop
    if @queue.empty?
      @reader << Fiber.current
      return Fiber.yield
    end

    value, fiber = @queue.shift
    fiber.resume
    return value
  end
end

module DRb
  class DRbUnknown
    def initialize(err, buf)
      @data = buf
    end

    def _dump(lv)
      @data
    end
  end
end

class DRbEchoServer
  def initialize(bartender, port)
    @rdv = Rdv.new
    Bartender::Server.new(bartender, port) do |reader, writer|
      begin
        while true
          _, msg, argv = req_drb(reader)
          if msg == "push"
            @rdv.push(argv)
            value = nil
          else
            value = @rdv.pop
          end
          reply_drb(writer, true, value)
        end
      rescue
        p $!
      end
    end
  end

  def req_drb(reader)
    ref = load(reader, false)
    msg = load(reader)
    argc = load(reader)
    argv = argc.times.collect { load(reader) }
    block = load(reader, false)
    [ref, msg, argv]
  end

  def reply_drb(writer, succ, result)
    writer.write(dump(succ) + dump(result))
  end

  def dump(obj)
    str = Marshal.dump(obj) rescue Marshal.dump(nil)
    [str.size].pack('N') + str
  end

  def load(reader, marshal=true)
    sz = reader.read(4)
    sz = sz.unpack('N')[0]
    data = reader.read(sz)
    return data unless marshal
    begin
      Marshal.load(data)
    rescue
      DRb::DRbUnknown.new($!, data)
    end
  end
end

DRbEchoServer.new(Bartender.primary, 12345)
Bartender.primary.run

