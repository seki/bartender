require 'bartender/bartender'

class ThreadTask
  def initialize(*args, &block)
    @pair = IO.pipe
    @task = Thread.new do 
      begin
        block.call(*args)
      ensure
        @pair[0].close
      end
    end
  end

  def value
    Bartender.select_readable(@pair[1]) if @pair
    @task.value
  ensure
    @pair[1].close if @pair
    @pair = nil
  end
end

if __FILE__ == $0
  Fiber.new do
    tt = ThreadTask.new {sleep 2; 'hello 2'}
    p tt.value
  end.resume

  Fiber.new do
    tt = ThreadTask.new {sleep 3; 'hello 3'}
    p tt.value
  end.resume

  Fiber.new do
    tt = ThreadTask.new {raise('hello 0')}
    (tt.value rescue $!).tap {|it| p it}
  end.resume

  Fiber.new do
    tt = ThreadTask.new {sleep 1; 'hello 1'}
    p tt.value
  end.resume

  Bartender.run
end
