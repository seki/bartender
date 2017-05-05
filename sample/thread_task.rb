require 'bartender/bartender'

if __FILE__ == $0
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

  Bartender.run
end
