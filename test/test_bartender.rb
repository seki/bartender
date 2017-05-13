require 'test/unit'
require 'bartender/bartender'

class TestBartender < Test::Unit::TestCase
  def test_thread_task
    expects = [
      'hello 0',
      'hello 1',
      'hello 2',
      'hello 3'
    ]

    Fiber.new do
      value = Bartender.task {sleep 2; 'hello 2'}.value
      assert_equal(value, expects.shift)
    end.resume
    
    Fiber.new do
      tt = Bartender::ThreadTask.new {sleep 3; 'hello 3'}
      value = tt.value
      assert_equal(value, expects.shift)
    end.resume
    
    Fiber.new do
      tt = Bartender.task {raise('hello 0')}
      (tt.value rescue $!).tap {|it| 
        assert_equal(it.to_s, expects.shift)
      }
    end.resume
    
    Fiber.new do
      tt = Bartender.task {sleep 1; 'hello 1'}
      value = tt.value
      assert_equal(value, expects.shift)
    end.resume
    
    Bartender.run

    assert(expects.empty?)
  end
end