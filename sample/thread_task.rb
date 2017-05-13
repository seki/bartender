require 'bartender/bartender'

if __FILE__ == $0
  queue = Queue.new
  Thread.new do
    5.times do |n|
      sleep 0.3
      queue.push([:que, n])
    end
  end
  
  Fiber.new do
    tt = Bartender::ThreadTask.new {sleep 2; 'hello 2'}
    p tt.value
  end.resume

  Fiber.new do
    tt = Bartender::ThreadTask.new {sleep 3; 'hello 3'}
    p tt.value
  end.resume

  Fiber.new do
    tt = Bartender::ThreadTask.new {raise('hello 0')}
    (tt.value rescue $!).tap {|it| p it}
  end.resume

  Fiber.new do
    tt = Bartender::ThreadTask.new {sleep 1; 'hello 1'}
    p tt.value
  end.resume

  Fiber.new do
    ary = 5.times.collect {
      Bartender.task {queue.pop}
    }
    ary.each { |x|
      p x.value
    }
  end.resume

  Bartender.run
end
