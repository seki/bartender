require 'bartender/bartender'
require 'socket'

class ThreadTask
  def initialize(bartender, *args, &block)
    @bartender = bartender
    @pair = UNIXSocket.pair
    @value = nil
    Thread.new do 
      begin
        @value = [true, block.call(*args)]
      rescue
        @value = [false, $!]
      ensure
        @pair[0].close
      end
    end
  end

  def join
    @bartender[:read, @pair[1]] = Fiber.current.method(:resume)
    Fiber.yield
    @value[0] ? @value[1] : raise(@value[1])
  ensure
    @bartender.delete(:read, @pair[1])
    @pair[1].close
    @pair = nil
  end
end

fiber = Fiber.new do
  tt = ThreadTask.new(Bartender.primary) {sleep 1; 'hello'}
  p tt.join
end
fiber.resume
fiber = Fiber.new do
  tt = ThreadTask.new(Bartender.primary) {sleep 2; 'hello 2'}
  p tt.join
end
fiber.resume
fiber = Fiber.new do
  tt = ThreadTask.new(Bartender.primary) {sleep 3; 'hello 3'}
  p tt.join
end
fiber.resume

Bartender.primary.run



