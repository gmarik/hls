#!/usr/bin/env ruby

# TODO:
# 1. How to print help if no params given

##
#
# Http Load Simulator
#
##
class Hls
  module Options
    require 'optparse'

    # parses command line options
    def self.parse
      # defaults
      options = {
        :rate => 10,
        :duration => 5,
        :uri => 'http://localhost:3000/'
      }
      
      OptionParser.new do |opt|
        opt.banner = <<-EOO
          Http load simulator
          Example: hls.rb -r 20 -d 1 -u 'http://localhost:3000/user/login'
          makes 20 requests per second during 1 second to 'http://localhost:3000/user/login' 
        EOO
        
        opt.on('-r RATE', '--rate', 'request RATE per second') do |v|
          options[:rate] = v
        end

        opt.on('-n DURATION', '--duration', 'total load DURATION time(seconds)') do |v|
          options[:duration] = v
        end

        opt.on('-u', '--uri URI', 'URI to request, with protocol(http:// etc) specified') do |u|
          options[:uri] = u
        end

        opt.on('-b [VERSBOSE_COUNT]', '--verbose-count', 'prints extra info each req/res number') do |vc|
          options[:vc] = vc
        end



        opt.separator ''
        opt.separator 'Common options:'

        opt.on_tail('-h', '--help', 'Show this help') do
          puts opt
          exit
        end
        
      end.parse!

      options
    end
  end

  require 'monitor'
  
  class Stat < Monitor
    
    attr_reader :options
    
    attr_reader :responses_num, :requests_num, :responses_num_failed, :requests_num_failed
    attr_reader :started_at, :stopped_at

    def initialize(options)
      @options = options
      @stat_data = {}
      @started_at = @stopped_at = nil
      @requests_num = 0
      @responses_num = 0
      @responses_num_failed = 0
      @requests_num_failed = 0

      super()
    end

    def duration
      stopped_at.to_f - started_at.to_f if @started_at && @stopped_at
    end

    def request_num
      @request_num ||= (@options[:rate].to_i * @options[:duration].to_i)
    end

    def delay
      @delay ||= (1.0 / @options[:rate].to_f) # milisec
    end

    def elapsed
      (Time.now - @started_at).to_i
    end

    def uri
      @uri || URI.parse(@options[:uri])
    end

    def response_rate
       @responses_num.to_f / @requests_num.to_f
    end

    def min_time
      @stat_data[:min_time]
    end

    def max_time
      @stat_data[:max_time]
    end

    def avg_time
      @stat_data[:sum_time] / self.request_num
    end

    def before_start(start_time)
      @started_at = start_time
    end

    def after_request(i, start_time)
      synchronize do
        @requests_num += 1
      end
    end

    def requests_failed(i, start)
      synchronize do
        @requests_num_failed += 1
      end
    end

    def response_failed(i, start, stop)
      synchronize do
        @responses_num_failed += 1
      end
    end

    def after_response(response, i, start, stop)
      synchronize do
        @responses_num += 1
      end
      
      time_taken = stop.to_f - start.to_f

      synchronize do
        @stat_data[:min_time] ||= time_taken 
        @stat_data[:min_time] = time_taken if time_taken < @stat_data[:min_time]

        @stat_data[:max_time] ||= time_taken
        @stat_data[:max_time] = time_taken if time_taken > @stat_data[:max_time]

        @stat_data[:sum_time] ||= 0
        @stat_data[:sum_time] += time_taken
      end
    end

    def after_stop(time)
      @stopped_at = time      
    end
  end

  class Printer

    def initialize(stat)
      @stat = stat
    end

    def progress
      str = ''
      unless @header_used
        str << '   Res/Req    = Completion, Elapsed(s)'
        str << "\n"
        @header_used = true
      end
      str << "#{'%6s' % @stat.responses_num}/#{'%-6s' % @stat.requests_num} = #{'%5.3f' % @stat.response_rate}, #{'%6s' % @stat.elapsed} "
    end

    def before_start(time) 
      print <<-OED
        #{'%5d' % @stat.request_num} : requests to run
        #{'%.3f' % @stat.delay} : delay between requests, seconds
        #{'%5d' % @stat.options[:rate]} : request rate, per second
        #{'%5d' % @stat.options[:duration]} : duration, seconds

        Uri : #{@stat.options[:uri]}
        Host: #{@stat.uri.host}
        Port: #{@stat.uri.port}
        Path: #{@stat.uri.path}

        Started: #{time}

        Please wait, this may take a while...
      OED
    end

    def after_request(i, start)
      puts self.progress if verbose_count?(:req)
    end

    def after_response(response, i, start, stop)
      puts "[#{response.code}] for response ##{i}" if response && response.code.to_i != 200 

      puts self.progress if verbose_count?(:res)
    end

    def response_failed(i, start, stop)                           
      unless @failed_response
        puts "First response #{i} - failed, at #{@stat.elapsed}"
        @failed_response = true
      end
    end

    def request_failed(i, time)                           
      unless @failed_request
        puts "First request #{i} - failed, at #{@stat.elapsed}"
        @failed_request = true
      end
    end

    def after_stop(time)

      print <<-OED

        #{progress}

        Requests  failed: #{@stat.requests_num_failed}
        Responses failed: #{@stat.responses_num_failed}

        Response timings(s):
        min: #{'%5.5f' % @stat.min_time}
        avg: #{'%5.5f' % @stat.avg_time}
        max: #{'%5.5f' % @stat.max_time}

        Completed in #{'%5.5f' % @stat.duration}s
      OED
    end

    protected
    def verbose_count?(s)
      vc = @stat.options[:vc].to_i
      
      if vc > 0
        return true if s == :res && @stat.responses_num > 0 && @stat.responses_num % vc == 0
        return true if s == :req && @stat.requests_num > 0 && @stat.requests_num % vc == 0
      end
      
      false
    end
  end

  attr_reader :stat

  def initialize()
    @stat = Stat.new(Options::parse)
    @printer = Printer.new(@stat)

    @observers = []

    setup()
  end

  require 'net/http'
  require 'uri'
  
  def run
    threads = []

    trap('INT') do
      p 'Caught, terminating'
      threads.each do |t|
        t.kill
      end
      
      exit
    end

    notify_observers :before_start, Time.now

    stat.request_num.times do |j|
      i = j + 1

      start = Time.now

      notify_observers :before_request, stat, i, start

      begin
        http = Net::HTTP.new(stat.uri.host, stat.uri.port)
        http.read_timeout = 120 # sec
      rescue
        notify_observers :request_failed, i, start
      else
        # TODO: isn't after request actually
        notify_observers :after_request, i, start
      end
      
      threads << Thread.new(i, start) do |i, start|
        Thread.current.abort_on_exception = true
        
        begin
          resp = http.get(stat.uri.path, nil)

          notify_observers :after_response, resp, i, start, Time.now
        rescue Exception => e
          notify_observers :response_failed, i, start, Time.now
        end
      end
      
      sleep(stat.delay)
    end

    threads.each {|t| t.join }

    notify_observers :after_stop, Time.now
  end

  protected

  def setup
    @observers << stat
    @observers << @printer
  end

  # TODO: notification in separate thread?
  def notify_observers(symbol, *args)
    @observers.each do |o|
      o.send(symbol, *args) if o.respond_to? symbol
    end
  end

end

Hls.new.run