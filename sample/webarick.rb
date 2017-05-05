require 'bartender/bartender'
require 'webrick/httpserver'

module WEBrick
  class GenericServer
    def start(&block)
      raise ServerError, "already started." if @status != :Stop
      server_type = @config[:ServerType] || SimpleServer

      @bartender = Bartender.context

      setup_shutdown_pipe

      server_type.start {
        @logger.info \
          "#{self.class}#start: pid=#{$$} port=#{@config[:Port]}"
        call_callback(:StartCallback)

        shutdown_pipe = @shutdown_pipe

        @status = :Running
        begin
          sp = shutdown_pipe[0]
          @bartender[:read, sp] = Proc.new do
            do_shutdown
          end

          @listeners.each do |svr|
            @bartender[:read, svr] = Proc.new do
              if sock = accept_client(svr)
                unless config[:DoNotReverseLookup].nil?
                  sock.do_not_reverse_lookup = !!config[:DoNotReverseLookup]
                end
                start_fiber(sock, &block)
              end
            end
          end
          @bartender.run
        ensure
          do_shutdown
        end
      }
    end

    def do_shutdown
      @bartender.stop
      cleanup_shutdown_pipe(@shutdown_pipe)
      cleanup_listener
      @status = :Shutdown
      @logger.info "going to shutdown ..."
      call_callback(:StopCallback)
      @logger.info "#{self.class}#start done."
      @status = :Stop
    end

    def start_fiber(sock, &block)
      begin
        begin
          addr = sock.peeraddr
          @logger.debug "accept: #{addr[3]}:#{addr[1]}"
        rescue SocketError
          @logger.debug "accept: <address unknown>"
          raise
        end
        call_callback(:AcceptCallback, sock)
        Fiber.new do
          begin
            block ? block.call(sock) : run(sock)
          rescue Errno::ENOTCONN
            @logger.debug "Errno::ENOTCONN raised"
          rescue ServerError => ex
            msg = "#{ex.class}: #{ex.message}\n\t#{ex.backtrace[0]}"
            @logger.error msg
          rescue Exception => ex
            @logger.error ex
          ensure
            if addr
              @logger.debug "close: #{addr[3]}:#{addr[1]}"
            else
              @logger.debug "close: <address unknown>"
            end
            sock.close unless sock.closed?
          end
        end.resume
      end
    end
  end
end

module WEBrick
  class HTTPServer
    def run(sock)
      while true
        res = HTTPResponse.new(@config)
        req = HTTPRequest.new(@config)
        server = self
        begin
          raise HTTPStatus::EOFError if @status != :Running
          req.parse(sock)
          res.request_method = req.request_method
          res.request_uri = req.request_uri
          res.request_http_version = req.http_version
          res.keep_alive = req.keep_alive?
          server = lookup_server(req) || self
          if callback = server[:RequestCallback]
            callback.call(req, res)
          elsif callback = server[:RequestHandler]
            msg = ":RequestHandler is deprecated, please use :RequestCallback"
            @logger.warn(msg)
            callback.call(req, res)
          end
          server.service(req, res)
        rescue HTTPStatus::EOFError, HTTPStatus::RequestTimeout => ex
          res.set_error(ex)
        rescue HTTPStatus::Error => ex
          @logger.error(ex.message)
          res.set_error(ex)
        rescue HTTPStatus::Status => ex
          res.status = ex.code
        rescue StandardError => ex
          @logger.error(ex)
          res.set_error(ex, true)
        ensure
          if req.request_line
            if req.keep_alive? && res.keep_alive?
              req.fixup()
            end
            res.send_response(sock)
            server.access_log(@config, req, res)
          end
        end
        break if @http_version < "1.1"
        break unless req.keep_alive?
        break unless res.keep_alive?
      end
    end
  end
end

module WEBrick
  class HTTPRequest
    def read_line(io, size=4096)
      @reader ||= Bartender::Reader.new(io)
      @reader.read_until(LF, size) 
    end

    def read_data(io, size)
      @reader ||= Bartender::Reader.new(io)
      @reader.read(size)
    end
  end

  class HTTPResponse
    def _write_data(socket, data)
      @writer ||= Bartender::Writer.new(socket)
      @writer.write(data)
    end
  end
end

if __FILE__ == $0
  server = WEBrick::HTTPServer.new({:BindAddress => 'localhost',
                                   :Port => 10080})
  server.start
end

