require 'bartender/bartender'
require 'fiber'

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

if __FILE__ == $0
  rdv = Rdv.new

  Fiber.new do
    tt = Bartender::ThreadTask.new {sleep 2; 'hello 2'}
    rdv.push(tt.value)
    p 2
  end.resume

  Fiber.new do
    tt = Bartender::ThreadTask.new {sleep 3; 'hello 3'}
    rdv.push(tt.value)
    p 3
  end.resume

  Fiber.new do
    tt = Bartender::ThreadTask.new {raise('hello 0')}
    (tt.value rescue $!).tap {|it| rdv.push(it)}
    p 0
  end.resume

  Fiber.new do
    tt = Bartender::ThreadTask.new {sleep 1; 'hello 1'}
    rdv.push(tt.value)
    p 1
  end.resume

  Fiber.new do
    p rdv.pop
    p rdv.pop
    p rdv.pop
    p rdv.pop
  end.resume

  Fiber.new do
    10.times do |n|
      Bartender.sleep(0.2)
      p [0.2, n]
    end
  end.resume

  Fiber.new do
    10.times do |n|
      Bartender.sleep(0.6)
      p [0.6, n]
    end
  end.resume

  bartender = Bartender.context
  entry = bartender.alarm(Time.now + 3, bartender.method(:stop))
  bartender.delete_alarm(entry)
  bartender.alarm(Time.now + 7, bartender.method(:stop))
  
  Bartender.run
end
