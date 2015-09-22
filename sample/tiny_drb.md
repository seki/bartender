# run server

    % ruby -I../lib tiny_drb.rb
    
# run client (irb)

    % irb -r drb
    irb(main):001:0> ro = DRbObject.new_with_uri('druby://localhost:12345')
    irb(main):002:0> ro.hello(1, 2.0, "3")
    => ["hello", [1, 2.0, "3"]]
    irb(main):003:0> 50.times.collect { Thread.new { ro.hello(ENV.to_hash.to_a * 10000) }}.each(&:join); nil
    