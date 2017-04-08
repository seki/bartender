# run server

    % ruby -I../lib tiny_drb.rb
    
# run client (irb)

    Terminal1
    % irb -r drb
    irb(main):001:0> ro = DRbObject.new_with_uri('druby://localhost:12345')
    irb(main):002:0> ro.push(1, 2.0, "3")
    
    Terminal2
    % irb -r drb 
    irb(main):001:0> ro = DRbObject.new_with_uri('druby://localhost:12345')
    irb(main):002:0> ro.pop
    => [1, 2.0, "3"]
