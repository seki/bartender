require 'bartender/bartender'

class Rdv
  def initialize
    @reader = []
    @queue = []
  end

  def push(it)
    if @reader.empty?
      @queue << [it, Fiber.current.method(:resume)]
      return Fiber.yield
    end

    @reader.shift.call(it)
  end

  def pop
    if @queue.empty?
      @reader << Fiber.current.method(:resume)
      return Fiber.yield
    end

    value, fiber = @queue.shift
    fiber.call
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
  def initialize(port)
    @rdv = Rdv.new
    Bartender::Server.new(port) do |soc|
      begin
        reader = Bartender::Reader.new(soc)
        writer = Bartender::Writer.new(soc)
        while true
          _, msg, argv = req_drb(reader)
          case msg
          when 'push'
            value = @rdv.push(argv)
          when 'pop'
            value = @rdv.pop
          else
            value = msg
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
    writer.write(dump(succ), true)
    writer.write(dump(result), true)
    writer.flush
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

DRbEchoServer.new(12345)
Bartender.run

