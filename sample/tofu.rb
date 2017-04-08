require 'erb'
require 'drb/drb'
require 'monitor'
require 'digest/md5'
require 'webrick'
require 'webrick/cgi'
require 'uri'

require 'webarick'

module Tofu
  class Session
    include MonitorMixin

    def initialize(bartender, hint=nil)
      super()
      @session_id = Digest::MD5.hexdigest(Time.now.to_s + __id__.to_s)
      @contents = {}
      @hint = hint
      renew
    end
    attr_reader :session_id
    attr_accessor :hint

    def service(context)
      case context.req_method
      when 'GET', 'POST', 'HEAD'
        do_GET(context)
      else
        context.res_method_not_allowed
      end
    end

    def expires
      Time.now + 24 * 60 * 60
    end

    def hint_expires
      Time.now + 60 * 24 * 60 * 60
    end

    def renew
      @expires = expires
    end

    def expired?
      @expires && Time.now > @expires
    end

    def do_GET(context)
      dispatch_event(context)
      tofu = lookup_view(context)
      body = tofu ? tofu.to_html(context) : ''
      context.res_header('content-type', 'text/html; charset=utf-8')
      context.res_body(body)
    end

    def dispatch_event(context)
      params = context.req_params
      tofu_id ,= params['tofu_id']
      tofu = fetch(tofu_id)
      return unless tofu
      tofu.send_request(context, context.req_params)
    end

    def lookup_view(context)
      nil
    end

    def entry(tofu)
      synchronize do
        @contents[tofu.tofu_id] = tofu
      end
    end
    
    def fetch(ref)
      @contents[ref]
    end
  end

  class SessionBar
    include MonitorMixin

    def initialize
      super()
      @pool = {}
      @keeper = keeper
      @interval = 60
    end

    def store(session)
      key = session.session_id
      synchronize do
        @pool[key] = session
      end
      @keeper.wakeup
      return key
    end

    def fetch(key)
      return nil if key.nil?
      synchronize do
        session = @pool[key]
        return nil unless session
        if session.expired?
          @pool.delete(key)
          return nil
        end
        return session
      end
    end

    private
    def keeper
      Thread.new do
        loop do
          synchronize do
            @pool.delete_if do |k, v| 
              v.nil? || v.expired?
            end
          end
          Thread.stop if @pool.size == 0
          sleep @interval
        end
      end
    end
  end

  class Bartender
    def initialize(factory, name=nil)
      @factory = factory
      @prefix = name ? name : factory.to_s.split(':')[-1]
      @bar = SessionBar.new
    end
    attr_reader :prefix

    def service(context)
      begin
      	session = retrieve_session(context)
	      catch(:tofu_done) { session.service(context) }
	        store_session(context, session)
      ensure
      end
    end

    private
    def retrieve_session(context)
      sid = context.req_cookie(@prefix + '_id')
      session = @bar.fetch(sid) || make_session(context)
      return session
    end

    def store_session(context, session)
      sid = @bar.store(session)
      context.res_add_cookie(@prefix + '_id', sid, session.expires)
      hint = session.hint
      if hint
	      context.res_add_cookie(@prefix +'_hint', hint, session.hint_expires)
      end
      session.renew
      return sid
    end

    def make_session(context)
      hint = context.req_cookie(@prefix +  '_hint')
      @factory.new(self, hint)
    end
  end

  class ERBMethod
    def initialize(method_name, fname, dir=nil)
      @fname = build_fname(fname, dir)
      @method_name = method_name
    end

    def reload(mod)
      erb = File.open(@fname) {|f| ERB.new(f.read)}
      erb.def_method(mod, @method_name, @fname)
    end
    
    private
    def build_fname(fname, dir)
      case dir
      when String
	      ary = [dir]
      when Array
        ary = dir
      else
        ary = $:
      end

      found = fname # default
      ary.each do |dir|
        path = File::join(dir, fname)
        if File::readable?(path)
          found = path
     	    break
    	  end
      end
      found
    end
  end

  class Tofu
    include DRbUndumped
    include ERB::Util

    @erb_method = []
    def self.add_erb(method_name, fname, dir=nil)
      erb = ERBMethod.new(method_name, fname, dir)
      @erb_method.push(erb)
    end

    def self.set_erb(fname, dir=nil)
      @erb_method = [ERBMethod.new('to_html(context=nil)', fname, dir)]
      reload_erb
    end

    def self.reload_erb1(erb)
      erb.reload(self)
    rescue SyntaxError
    end

    def self.reload_erb
      @erb_method.each do |erb|
        reload_erb1(erb)
      end
    end

    def initialize(session)
      @session = session
      @session.entry(self)
      @tofu_seq = nil
    end
    attr_reader :session

    def tofu_class
      self.class.to_s
    end

    def tofu_id
      self.__id__.to_s
    end

    def to_div(context)
      to_elem('div', context)
    end

    def to_span(context)
      to_elem('span', context)
    end

    def to_elem(elem, context)
      elem('elem', {'class'=>tofu_class, 'id'=>tofu_id}) {
        begin
          to_html(context)
        rescue
          "<p>error! #{h($!)}</p>"
        end
      }
    end

    def to_html(context); ''; end

    def to_inner_html(context)
      to_html(context)
    end

    def send_request(context, params)
      cmd, = params['tofu_cmd']
      msg = 'do_' + cmd.to_s

      if @tofu_seq
        seq, = params['tofu_seq']
        unless @tofu_seq.to_s == seq
          p [seq, @tofu_seq.to_s] if $DEBUG
          return
      	end
      end

      if respond_to?(msg)
      	send(msg, context, params)
      else
      	do_else(context, params)
      end
    ensure
      @tofu_seq = @tofu_seq.succ if @tofu_seq
    end

    def do_else(context, params)
    end

    def action(context)
      context.req_script_name.to_s + context.req_path_info.to_s
    end

    private
    def attr(opt)
      ary = opt.collect do |k, v|
        if v 
          %Q!#{k}="#{h(v)}"!
        else
          nil
        end
      end.compact
      return nil if ary.size == 0 
      ary.join(' ')
    end

    def elem(name, opt={})
      head = ["#{name}", attr(opt)].compact.join(" ")
      if block_given?
        %Q!<#{head}>\n#{yield}\n</#{name}>!
      else
      	%Q!<#{head} />!
      end  
    end

    def make_param(method_name, add_param={})
      param = {
        'tofu_id' => tofu_id,
        'tofu_cmd' => method_name
      }
      param['tofu_seq'] = @tofu_seq if @tofu_seq
      param.update(add_param)
      return param
    end

    def form(method_name, context_or_param, context_or_empty=nil)
      if context_or_empty.nil? 
        context = context_or_param
        add_param = {}
      else
        context = context_or_empty
        add_param = context_or_param
      end
      param = make_param(method_name, add_param)
      hidden = input_hidden(param)
      %Q!<form action="#{action(context)}" method="post">\n! + hidden
    end

    def href(method_name, add_param, context)
      param = make_param(method_name, add_param)
      ary = param.collect do |k, v|
	      "#{u(k)}=#{u(v)}"
      end
      %Q!href="#{action(context)}?#{ary.join(';')}"!
    end

    def input_hidden(param)
      ary = param.collect do |k, v|
	      %Q!<input type="hidden" name="#{h(k)}" value="#{h(v)}" />\n!
      end
      ary.join('')
    end

    def make_anchor(method, param, context)
      "<a #{href(method, param, context)}>"
    end

    def a(method, param, context)
      make_anchor(method, param, context)
    end
  end

  def reload_erb
    ObjectSpace.each_object(Class) do |o|
      if o.ancestors.include?(Tofu::Tofu)
	      o.reload_erb
      end
    end
  end
  module_function :reload_erb

  class Context
    def initialize(req, res)
      @req = req
      @res = res
    end
    attr_reader :req, :res

    def done
      throw(:tofu_done)
    rescue NameError
      nil
    end

    def service(bartender)
      bartender.service(self)
      nil
    end

    def req_params
      hash = {}
      @req.query.each do |k,v|
	      hash[k] = v.list
      end
      hash
    end

    def req_cookie(name)
      found = @req.cookies.find {|c| c.name == name}
      found ? found.value : nil
    end

    def res_add_cookie(name, value, expires=nil)
      c = WEBrick::Cookie.new(name, value)
      c.expires = expires if expires
      @res.cookies.push(c)
    end
    
    def req_method
      @req.request_method
    end
    
    def res_method_not_allowed
      raise HTTPStatus::MethodNotAllowed, "unsupported method `#{req_method}'."
    end
    
    def req_path_info
      @req.path_info
    end

    def req_script_name
      @req.script_name
    end
    
    def req_absolute_path
      (@req.request_uri + '/').to_s.chomp('/')
    end

    def res_body(v)
      @res.body = v
    end

    def res_header(k, v)
      if k.downcase == 'status'
	      @res.status = v.to_i
	      return
      end
      @res[k] = v
    end
  end

  class Tofulet < WEBrick::HTTPServlet::AbstractServlet
    def initialize(config, bartender, *options)
      @bartender = bartender
      super(config, *options)
      @logger.debug("#{self.class}(initialize)")
    end
    attr_reader :logger, :config, :options, :bartender

    def service(req, res)
      Context.new(req, res).service(@bartender)
    end
  end

  class CGITofulet < WEBrick::CGI
    def initialize(bartender, *args)
      @bartender = bartender
      super(*args)
    end
    
    def service(req, res)
      Context.new(req, res).service(@bartender)
    end
  end
end

module Tofu
  class Tofu
    def update_js
      <<-"EOS"
      function tofu_x_eval(tofu_id) {
        var ary = document.getElementsByName(tofu_id + "tofu_x_eval");
        for (var j = 0; j < ary.length; j++) {
          var tofu_arg = ary[j];
          for (var i = 0; i < tofu_arg.childNodes.length; i++) {
            var node = tofu_arg.childNodes[i];
            if (node.attributes.getNamedItem('name').nodeValue == 'tofu_x_eval') {
              var script = node.attributes.getNamedItem('value').nodeValue;
              try {
                 eval(script);
              } catch(e) {
              }
            }
          }
        }
      }

      function tofu_x_update(tofu_id, url) {
        var x;
        try {
          x = new ActiveXObject("Msxml2.XMLHTTP");
        } catch (e) {
          try {
            x = new ActiveXObject("Microsoft.XMLHTTP");
          } catch (e) {
            x = null;
          }
        }
        if (!x && typeof XMLHttpRequest != "undefined") {
           x = new XMLHttpRequest();
        }
        if (x) {
          x.onreadystatechange = function() {
            if (x.readyState == 4 && x.status == 200) {
              var tofu = document.getElementById(tofu_id);
              tofu.innerHTML = x.responseText;
              tofu_x_eval(tofu_id);
            }
          }
          x.open("GET", url);
          x.send(null);
        }
      }
EOS
    end

    def a_and_update(method_name, add_param, context, target=nil)
      target ||= self
      param = {
        'tofu_inner_id' => target.tofu_id
      }
      param.update(add_param)

      param = make_param(method_name, param)
      ary = param.collect do |k, v|
	      "#{u(k)}=#{u(v)}"
      end
      path = URI.parse(context.req_absolute_path)
      url = path + %Q!#{action(context)}?#{ary.join(';')}!
      %Q!tofu_x_update("#{target.tofu_id}", #{url.to_s.dump});!
    end

    def on_update_script(ary_or_script)
      ary = if String === ary_or_script
              [ary_or_script]
            else
              ary_or_script
            end
      str = %Q!<form name="#{tofu_id}tofu_x_eval">!
      ary.each do |script|
        str << %Q!<input type='hidden' name='tofu_x_eval' value="#{script.gsub('"', '&quot;')}" />!
      end
      str << '</form>'
      str
    end

    def update_me(context)
      a_and_update('else', {}, context)
    end

    def update_after(msec, context)
      callback = update_me(context)
      script = %Q!setTimeout(#{callback.dump}, #{msec})!
      on_update_script(script)
    end
  end
  
  class Session
    def do_inner_html(context)
      params = context.req_params
      tofu_id ,= params['tofu_inner_id']
      return false unless tofu_id

      tofu = fetch(tofu_id)
      body = tofu ? tofu.to_inner_html(context) : ''

      context.res_header('content-type', 'text/html; charset=utf-8')
      context.res_body(body)

      throw(:tofu_done)
    end
  end
end

if __FILE__ == $0
  require 'pp'

  class EnterTofu < Tofu::Tofu
    ERB.new(<<EOS).def_method(self, 'to_html(context)')
<%=form('enter', {}, context)%>
<dl>
<dt>hint</dt><dd><%=h @session.hint %><input class='enter' type='text' size='40' name='hint' value='<%=h @session.hint %>'/></dd>
<dt>volatile</dt><dd><%=h @session.text %><input class='enter' type='text' size='40' name='text' value='<%=h @session.text%>'/></dd>
</dl>
<input type='submit' />
</form>
EOS
    def do_enter(context, params)
      hint ,= params['hint']
      @session.hint = hint || ''
      text ,= params['text']
      @session.text = text || ''
    end
  end

  class BaseTofu < Tofu::Tofu
    ERB.new(<<EOS).def_method(self, 'to_html(context)')
<html><title>base</title><body>
Hello, World.
<%= @enter.to_html(context) %>
<hr />
<pre><%=h context.pretty_inspect%></pre>
</body></html>
EOS
    def initialize(session)
      super(session)
      @enter = EnterTofu.new(session)
    end
  end

  class HelloSession < Tofu::Session
    def initialize(bartender, hint=nil)
      super
      @base = BaseTofu.new(self)
      @text = ''
    end
    attr_accessor :text

    def lookup_view(context)
      @base
    end
  end

  tofu = Tofu::Bartender.new(HelloSession)
  s = WEBrick::HTTPServer.new(:Port => 8080)
  s.mount("/", Tofu::Tofulet, tofu)
  s.start
end
