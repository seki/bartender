require 'bartender/bartender'

module Bartender
  module_function

  def self.select(*chan)
    once = false
    if chan[-1] == true || chan[-1] == false
      once = chan.pop
    end

    chan.each do |ch|
      succ, value = ch.signal?
      return ch, value if succ
    end

    return nil, nil if once

    chan.each do |ch|
      ch.signal?(false)
    end

    ch, value = Fiber.yield

    chan.each do |ch|
      ch.cancel
    end

    return ch, value
  end

  class Chan
    class Op
      def cancel
        @chan.cancel
      end
      
      def ===(ot)
        @chan == ot || super(ot)
      end
    end
    
    class Reader < Op
      def initialize(chan)
        @chan = chan
      end

      def signal?(nonblock=true)
        succ, value = @chan.pop?
        if succ || nonblock
          return succ, value
        end

        @chan.reader << [Fiber.current, self]
        return false, nil
      end
    end

    class Writer < Op
      def initialize(chan, value)
        @chan = chan
        @value = value
      end

      def signal?(nonblock=true)
        succ = @chan.push?(@value)
        if succ || nonblock
          return succ
        end

        @chan.queue << [@value, [Fiber.current, self]]
        return false, nil
      end
    end
    
    def initialize
      @reader = []
      @queue = []
    end
    attr_reader :reader, :queue

    def ===(ot)
      super(ot) || ot === self
    end
    
    def cancel
      @reader.delete_if {|f| f[0] == Fiber.current}
      @queue.delete_if {|v, f|  f[0] == Fiber.current}
    end

    def push?(it)
      return false if @reader.empty?
      fiber, *arg = @reader.shift
      fiber.resume(*arg, it)
      return true
    end

    def pop?
      return false, nil if @queue.empty?
      value, cb = @queue.shift
      fiber, *arg = cb
      fiber.resume(*arg)
      return true, value
    end

    def push!(it)
      Writer.new(self, it)
    end

    def pop!
      Reader.new(self)
    end

    def push(it)
      return nil if push?(it)

      @queue << [it, [Fiber.current]]
      Fiber.yield
    end
    
    def pop
      succ, value = pop?
      return value if succ

      @reader << [Fiber.current]
      Fiber.yield
    end
  end
end

ch = Bartender::Chan.new
ch2 = Bartender::Chan.new
quit = Bartender::Chan.new

Fiber.new do
  Bartender.sleep(5)
  quit.push(:quit)
end.resume

Fiber.new do
  10.times do |n|
    Bartender.sleep(rand)
    ch.push(n)
  end
end.resume

Fiber.new do
  3.times do |n|
    Bartender.sleep(rand)
    p ch2.pop
  end
end.resume

Fiber.new do
  while true
    chan, value = Bartender::select(ch.pop!, ch2.push!(:out), quit.pop!)
    case chan
    when ch
      p [:ch, value]
    when ch2
      p [:ch2, value]
    when quit
      p [:quit, value]
      break
    else
      p :else
      Bartender.sleep(0.5)
    end
  end
end.resume

Bartender.run
