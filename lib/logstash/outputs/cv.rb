# encoding: utf-8
require "logstash/outputs/base"
require "logstash/namespace"
require "logstash/json"
require "uri"
require "logstash/plugin_mixins/http_client"
require 'json'
require 'nokogiri'
require 'stud/buffer'
java_import java.util.concurrent.locks.ReentrantLock

class LogStash::Outputs::Cv < LogStash::Outputs::Base
  include LogStash::PluginMixins::HttpClient
  include Stud::Buffer

  concurrency :shared

  VALID_METHODS = ["put", "post", "patch", "delete", "get", "head"]

  RETRYABLE_MANTICORE_EXCEPTIONS = [
    ::Manticore::Timeout,
    ::Manticore::SocketException,
    ::Manticore::ClientProtocolException,
    ::Manticore::ResolutionFailure,
    ::Manticore::SocketTimeout
  ]

  # This output lets you send events to a
  # Commvault datacube output
  #
  # This output will execute up to 'pool_max' requests in parallel for performance.
  # Consider this when tuning this plugin for performance.
  #
  # Additionally, note that when parallel execution is used strict ordering of events is not
  # guaranteed!
  #
  config_name "cv"

  # URL to use
  #config :url, :validate => :string, :required => :true

  # The HTTP Verb. One of "put", "post", "patch", "delete", "get", "head"
  config :http_method, :validate => VALID_METHODS, :required => :true

  # Custom headers to use
  # format is `headers => ["X-My-Header", "%{host}"]`
  config :headers, :validate => :hash

  # Content type
  #
  # If not specified, this defaults to the following:
  #
  # * if format is "json", "application/json"
  # * if format is "form", "application/x-www-form-urlencoded"
  config :content_type, :validate => :string

  # Set this to false if you don't want this output to retry failed requests
  config :retry_failed, :validate => :boolean, :default => true

  # If encountered as response codes this plugin will retry these requests
  config :retryable_codes, :validate => :number, :list => true, :default => [429, 500, 502, 503, 504, 401]

  # If you would like to consider some non-2xx codes to be successes
  # enumerate them here. Responses returning these codes will be considered successes
  config :ignorable_codes, :validate => :number, :list => true

  # This lets you choose the structure and parts of the event that are sent.
  #
  #
 
 
  config :mapping, :validate => :hash

  # Set the format of the http body.
  #
  # If form, then the body will be the mapping (or whole event) converted
  # into a query parameter string, e.g. `foo=bar&baz=fizz...`
  #
  # If message, then the body will be the result of formatting the event according to message
  #
  # Otherwise, the event is sent as json.
  config :format, :validate => ["json", "form", "message"], :default => "json"

  config :message, :validate => :string

  config :username_cv, :validate => :string, :required => :true
  config :password_cv, :validate => :string, :required => :true
  config :datasourcename_cv, :validate => :string, :required => :true
  config :hostname_cv, :validate => :string, :required => true
  config :portnum_other_cv_webconsole, :validate => :string, :required => :false, :default => '80'
  config :portnum_other_cv_searchSvc, :validate => :string, :required => :false, :default => '81'
  config :template_file, :validate => :string, :required => :false, :default => ''

 
  config :portnum_authentication_cv_webconsole, :validate => :string, :required => :false, :default => '80'
  config :portnum_authentication_cv_searchSvc, :validate => :string, :required => :false, :default => '81'
  config :flush_size, :validate => :number, :required => :false, :default => '100'
  config :idle_flush_time, :validate => :number, :required => :false, :default => '30'
  config :webconsole, :validate => :boolean, :required => :false, :default =>false 
  @@retry_num = 5 # to retry method: get_data_source_id
  @@retry_num_auth_token = 2 # to retry method: get_auth_tkn

  public
  def register
    @http_method = @http_method.to_sym

    # We count outstanding requests with this queue
    # This queue tracks the requests to create backpressure
    # When this queue is empty no new requests may be sent,
    # tokens must be added back by the client on success

    @state_lock = ReentrantLock.new

    @pool_max = 50
    @request_tokens = SizedQueue.new(@pool_max)
    @pool_max.times {|t| @request_tokens << true }

    @requests = Array.new

    if @content_type.nil?
      case @format
        when "form" ; @content_type = "application/x-www-form-urlencoded"
        when "json" ; @content_type = "application/json"
        when "message" ; @content_type = "text/plain"
      end
    end

    validate_format!

    # Run named Timer as daemon thread
    @timer = java.util.Timer.new("HTTP Output #{self.params['id']}", true)

    synchronize do # remove synchronization and try
      if not @auth_token
        get_auth_tkn
      end

      if @datasourceid
        if @webconsole == true 
        host_address = @hostname_cv + ':' + @portnum_other_cv_webconsole
      else
        host_address = @hostname_cv + ':' + @portnum_other_cv_searchSvc
      end
      
      if @webconsole == true
        @url = "http://#{host_address}/webconsole/api/dcube/post/json/#{@datasourceid}"
      else
         @url="http://#{host_address}/SearchSvc/CVWebService.svc/post/json/#{@datasourceid} " 
      end   
      else
        get_data_source_id
        datasource_fields
      end
    end # synchronize do
    desynchronize

    #for batch requests
    buffer_initialize(
      :max_items => @flush_size,
      :max_interval => @idle_flush_time,
      :logger => @logger
    )
  end # def register

  public
  def multi_receive(events)
    @logger.info( "***************multi_receive***************")

    events.each { |event| buffer_receive(event) }
  end 

  class RetryTimerTask < java.util.TimerTask
    def initialize(pending, event, attempt)
      @pending = pending
      @event = event
      @attempt = attempt
      super()
    end

    def run
      @pending << [@event, @attempt]
    end
  end

  def flush(events, final)
    documents = []
    events.each do |event|
        document = event.to_hash()
        documents.push(document)
    end
    make_batch_request(documents)
  end



  def send_events(events)
    successes = java.util.concurrent.atomic.AtomicInteger.new(0)
    failures  = java.util.concurrent.atomic.AtomicInteger.new(0)
    retries = java.util.concurrent.atomic.AtomicInteger.new(0)

    pending = Queue.new
    events.each {|e| pending << [e, 0]}

    while popped = pending.pop
      break if popped == :done

      event, attempt = popped

      send_event(event, attempt) do |action,event,attempt|
        begin
          action = :failure if action == :retry && !@retry_failed

          case action
          when :success
            successes.incrementAndGet
          when :retry
            retries.incrementAndGet

            next_attempt = attempt+1
            sleep_for = sleep_for_attempt(next_attempt)
            @logger.info("Retrying http request, will sleep for #{sleep_for} seconds")
            timer_task = RetryTimerTask.new(pending, event, next_attempt)
            @timer.schedule(timer_task, sleep_for*1000)
          when :failure
            failures.incrementAndGet
          else
            raise "Unknown action #{action}"
          end

          if action == :success || action == :failure
            if successes.get+failures.get == events.size
              pending << :done
            end
          end
        rescue => e
          # This should never happen unless there's a flat out bug in the code
          @logger.error("Error sending HTTP Request",
            :class => e.class.name,
            :message => e.message,
            :backtrace => e.backtrace)
          failures.incrementAndGet
          raise e
        end
      end
    end
  rescue => e
    @logger.error("Error in http output loop",
            :class => e.class.name,
            :message => e.message,
            :backtrace => e.backtrace)
    raise e
  end

  def sleep_for_attempt(attempt)
    sleep_for = attempt**2
    sleep_for = sleep_for <= 60 ? sleep_for : 60
    (sleep_for/2) + (rand(0..sleep_for)/2)
  end

  def make_client_cv
    Manticore::Client.new
  end

  def client_cv
    @client ||= make_client_cv
  end

  def datasource_fields
    @logger.info ("****************datasource_fields************************************")

    if @datasourceid && @template_file != ''
      file = File.read(@template_file)
      begin
        data_hash = JSON.parse(file)
      rescue JSON::ParserError => e
        @logger.error("Error while parsing JSON, in method: datasource_fields variable: data_hash")
      end

      body = Nokogiri::XML::Builder.new { |xml|
        xml.DM2ContentIndexing_ManageSchemaReq("datasourceId" => @datasourceid) do

          xml.schema do
            data_hash.keys.each do |key|
              node = xml.schemaFields
              node["fieldName"] = key
              data_hash_ = data_hash[key]
              data_hash_.keys.each do |key2|
                node[key2] = data_hash_[key2]
              end
            end
          end
        end
      }.to_xml save_with:3
      @logger.info ("****************EASYTOIDENTIFY************************************")
      @logger.info(body)
      headers = {'Accept' => 'application/xml', 'Authtoken' => @auth_token}

       if @webconsole == true 
        host_address = @hostname_cv + ':' + @portnum_other_cv_webconsole
      else
        host_address = @hostname_cv + ':' + @portnum_other_cv_searchSvc
      end
     if @webconsole ==true
      url = "http://#{host_address}/webconsole/api/dcube/updateschema"
      else
        url="http://#{host_address}/SearchSvc/CVWebService.svc/dcube/updateschema"
      end
   
      http_method = "post"
      begin
      response = client_cv.post( url, :body => body, :headers => headers).body
      @logger.info( response)
  # begin
        #api call to create new data source
       # response_body = client_cv.post(url_create_datasource, :headers => headers_creae_datasource, :body => modified_body).body
      rescue => e
        #should retry?
        @logger.error( "Error  changing schema ", response)
      else
        reader = Nokogiri::XML::Reader(response)
        reader.each {
          |node| if node.name.eql? "DM2ContentIndexing_Error" and node.attribute('errorCode').eql? "0"
                  @logger.info(" success ")
                end
        }

      end
      # reponse.on_success             
      #   @logger.info( 'field request completed', reponse.body)
      #   #do some logging here
      #   #puts ''
      #   #@request_tokens << token      
      #   @logger.info('Update schema check')
      #   @logger.info(response)
      #   if request.code >= 200 && request.code < 300
      #   	response = request.body

      #     #success do logging
      #   end
      # }.on_failure{

      #   @logger.error( 'Error in field request')}
     

   
    end # if @datasourceid
  end # datasource_fields

  def get_data_source_id
    #this function, gets datasourceid and generates url
    #synchronize do
    @logger.info( "****************get_data_source_id************************************")

    headers = {'Accept' => 'application/json', 'Authtoken' => @auth_token}
    retries_datasourceid_api = 10
    datasourceid = -1
    begin
      # api call to get all data sources of type 11
       if @webconsole == true 
        host_address = @hostname_cv + ':' + @portnum_other_cv_webconsole
      else
        host_address = @hostname_cv + ':' + @portnum_other_cv_searchSvc
      end
      if @webconsole == true
        res = client_cv.get("http://#{host_address}/webconsole/api/dcube/GetDataSources?type=11", :headers => headers)
      else
        res = client_cv.get("http://#{host_address}/SearchSvc/CVWebService.svc/dcube/GetDataSources?type=11", :headers => headers)
      end  
    rescue => e
    #rescue Manticore::SocketTimeout => e
      @logger.error( "Error getting datasource id response")
      if( retries_datasourceid_api -= 1 ) > 0
        @logger.info( "Will retry")
        retry
      else
         @logger.info( "Not retrying, Aborting")
        abort
      end
    else
      response_body = res.body
      #puts response_body
      begin
        response_body_hash = JSON.parse(response_body)
      rescue JSON::ParserError => e
        @logger.error( "Error in variable format :response_body")
        # if ( res.code == 401 )
        #   puts 'Wrong/Expired authentication token, Retrying'
        # end
        if ( @@retry_num -= 1 ) > 0
          @logger.info( "Sleeping for 10 seconds, before calling method: get_data_source_id")
          sleep(10)
          get_data_source_id
        else
          abort
        end
      end
      response_body_arr = response_body_hash["collections"]
      if !response_body_arr.nil?
        for i in 0..response_body_arr.length
          if !response_body_arr[i].nil? and !response_body_arr[i]["datasources"].nil?
            data_hash = response_body_arr[i]["datasources"][0]
            if data_hash["datasourceName"].eql? @datasourcename_cv
              datasourceid = data_hash["datasourceId"]
              break
            end
          end
        end
      end
    end
    #puts datasourceid
    @datasourceid = datasourceid
    if datasourceid != -1
      # the datasource exists; create the url for sending events using the
      # datasource ID and return it
      #puts "data source id = #{datasourceid}"
    if @webconsole==true
      @url = "http://#{host_address}/webconsole/api/dcube/post/json/#{datasourceid}"
    else
      @url = "http://#{host_address}/SearchSvc/CVWebService.svc/dcube/post/json/#{datasourceid}"  
    end
    else
      # the datasource does not exist; create datasource; create url for
      # sending events; return it
      @logger.info( '*******************************creating new data source*******************************')

      if @webconsole==true
       url_create_datasource = "http://#{host_address}/webconsole/api/dcube/createDataSource"
      else
         url_create_datasource = "http://#{host_address}/SearchSvc/CVWebService.svc/dcube/createDataSource"
       end
      headers_create_datasource = { 'Accept' => 'application/xml', 'Authtoken' => @auth_token}
      body_create_datasource = '<DM2ContentIndexing_CreateDataSourceReq>
                                  <collectionReq collectionName="replace_datasourceName">
                                      <ciserver cloudID="replace_cloudID"/>
                                  </collectionReq>
                                  <dataSource datasourceName="replace_datasourceName" datasourceType="11" description="" attribute="0"/>
                                </DM2ContentIndexing_CreateDataSourceReq>'

      modified_body = body_create_datasource.gsub('replace_datasourceName', @datasourcename_cv)

     
      if @webconsole==true
       url_cloudid_api = "http://#{host_address}/webconsole/api/dcube/getAnalyticsEngine"
    else
     url_cloudid_api = "http://#{host_address}/SearchSvc/CVWebService.svc/dcube/getAnalyticsEngine"  
    end

      # headers for createing data source api and view analytics


      # engine api are same; will reuse
      #headers_create_datasource = {'Host' => 'WIN-1HUNONJ7DS5:81', 'Accept' => 'application/xml', 'Authtoken' => @auth_token}

      retries_cloudid_api = 3
      cloudid = -1
      begin
        # api call to get cloud id
        response_cloudid_api = client_cv.get(url_cloudid_api, :headers => headers_create_datasource).body
      rescue => e
        @logger.error( "Error getting cloud ID")
        if( retries_cloudid_api -= 1 ) > 0
          @logger.info( "Will retry")
          retry
        else
           @logger.info( "Not retrying")
        end
      else
        reader = Nokogiri::XML::Reader(response_cloudid_api)
        reader.each {
          |node| if node.name.eql? "listOfCIServer" and node.attribute('hostName').eql? "WIN-1HUNONJ7DS5"
                  cloudid = node.attribute('cloudID')
                end
        }
      end

      if cloudid == -1
        @logger.error( "***************************Error in fetching cloudID********************************")
        #error handling here
      else
        #puts "*****************************CloudID = #{cloudid}********************************"
        modified_body = modified_body.gsub('replace_cloudID', cloudid)
      end

      begin
        #api call to create new data source
        response_body = client_cv.post(url_create_datasource, :headers => headers_create_datasource, :body => modified_body).body
      rescue => e
        #should retry?
        @logger.error( "Error creating new data source")
      else
        reader = Nokogiri::XML::Reader(response_body)
        reader.each {
          |node| if node.name.eql? "datasources" and node.attribute('datasourceName').eql? @datasourcename_cv
                  datasourceid = node.attribute('datasourceId')
                end
        }
      end
      #puts datasourceid
      @datasourceid = datasourceid
      if datasourceid == -1
        @logger.error( "*****************************Error in creating new open data source.********************************")
      else
        if @webconsole==true
          @url = "http://#{host_address}/webconsole/api/dcube/post/json/#{datasourceid}"
        else
          @url="http://#{host_address}/SearchSvc/CVWebService.svc/dcube/post/json/#{datasourceid}"
      end

    end
    end # if datasourceid != -1
    @logger.info( "*****************************URL = #{@url}********************************")
    #end # synchronize do
    #desynchronize
  end # def get_data_source_id

  def get_auth_tkn
    @logger.info( "****************get_auth_tkn************************************")

    #TODO : test get_auth_tkn
    if @hostname_authentication_cv.to_s.strip.empty?
      @hostname_authentication_cv = @hostname_cv
    end
    if @username_authentication_cv.to_s.strip.empty?
      @username_authentication_cv = @username_cv
    end
    if @password_authentication_cv.to_s.strip.empty?
      @password_authentication_cv = @password_cv
    end
    if @webconsole==true
    auth_host = @hostname_authentication_cv+':'+@portnum_authentication_cv_webconsole   
  else
    auth_host = @hostname_authentication_cv+':'+@portnum_authentication_cv_searchSvc
  end
    if @webconsole ==true
     authurl = "http://#{auth_host}/webconsole/api/Login"
    else
     authurl = "http://#{auth_host}/SearchSvc/CVWebService.svc/Login"
    end 
    auth_body = {mode: 'WebConsole', domain: '', username: @username_authentication_cv, password: @password_authentication_cv, commserver: ''}.to_json
    auth_headers = { 'Content-Type' => 'application/json', 'Accept' => 'application/json'}

    token = -1
    retries_authtoken_api = 3
    begin
      response_body = client_cv.post(authurl, :headers => auth_headers, :body => auth_body).body
    rescue => e
      @logger.error( "Error getting auth token")
      if( retries_authtoken_api -= 1 ) > 0
        @logger.info( "Will retry")
        retry
      else
        @logger.info( "Not retrying")
      end
    else
      begin
        response_body_hash = JSON.parse(response_body)
      rescue JSON::ParserError => e
         @logger.info( "Error in variable format :response_body in method: get_auth_tkn")
        if ( @@retry_num_auth_token -= 1 ) > 0
          @logger.info( "Sleeping for 2 seconds, before calling method: get_auth_tkn")
          sleep(2)
          #TODO: should call method or just make another api call to get auth_token?????
          get_auth_tkn
        else
          abort
        end
      end
      token = response_body_hash["token"]
      #positions = response_body.enum_for(:scan, /token/).map { Regexp.last_match.begin(0) } # works
      #token = response_body[positions[0]+8..-1][/^(.*?)(")/, 1]
    end
    if token != -1
      @auth_token = token
    else
      @logger.error ("Error generating auth token")
    end
  end

  def synchronize
      # The JRuby Mutex uses lockInterruptibly which is what we DO NOT want
      @state_lock.lock()
      yield
    #ensure
    #  @state_lock.unlock()
  end

  def desynchronize
    @state_lock.unlock()
  end

  def make_batch_request(documents)
    @logger.info("@@@@@@@@@@@@@@@@@@@@@@@@@make_batch_request@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@")

    body = LogStash::Json.dump(documents)
    #token = @request_tokens.pop
    url = @url
    #auth_token_debug = "QSDK 3e071c1999f9d1c04ad9c998b9bc3f8c9d9b6088f0ec1bf360e446935b69e7e5501062da581960fb2e70aee1ad39a75a4d511aa2effa22bcb2efdf9bd9e8e054fa9e4060bd782b38e063219da19415554cffe4a4700d02987721e0d54bb9c0eff300509cd549536c769cb5979581ea8cfd517a02432968594c9d6cb94149138229ea96f6c06727a285b5a680ab3133492fc87a5533a92746799db833a16c19b901b2f8cc46cfe2cba5397db1096aecb2361906f02e682841a2dc8cf5c71863fe276ec7b3c2dfda0a72095b84e680ec26f80cec9ab986b14011ea8a558b4fef37dbe0203f49bac50f99f0fc09f1546c1e19bd310d222d3be321ebaee0949fd31d5288898f916a1387bb2b481208d7534b33"
    headers = {'Content-type' => 'application/json', 'Accept' => 'application/json', 'Authtoken' => @auth_token} # TODO: call event_headers to get headers ds

    begin
      request = client_cv.background.send(@http_method, url, :body => body, :headers => headers)
      request.call
    rescue Exception => e
      @logger.error( 'Error occurred while making batch request')
    end

    request.on_complete do
      @logger.info('Batch request completed.')
      #@request_tokens << token
    end

    request.on_success do |response|
      if response.code >= 200 && response.code < 300
         @logger.info( 'Batch request successful')
      elsif response.code == 401
         @logger.info( 'Attempting to reconnect.')
        get_auth_tkn
      else
         @logger.info( 'response code = #{response.code}')
        # check if response.code is retryable
        # >> finding which event sent the bad response.code
        # >> send all events of this batch for single event processing at a time
        #send_events(events)
      end
    end

    request.on_failure do |exception|
      @logger.error( 'Error in sending batch request, unable to connect to endpoint')
      # do something here
    end
  end # make_batch_request



  def send_event(event, attempt)
    @logger.info("@@@@@@@@@@@@@@@@@@@@@@@@@inside send_event@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@")
    body = event_body(event)

    # Send the request
    #@url = "http://172.16.196.227/webconsole/api/dcube/post/json/6"
    url = event.sprintf(@url)
    headers = event_headers(event)
    # Create an async request
    request = client.background.send(@http_method, url, :body => body, :headers => headers)
    request.call # Actually invoke the request in the background

    request.on_success do |response|
      begin
        if !response_success?(response)
          if response.code == 401
             @logger.info( 'Attempting to reconnect')
            get_auth_tkn
          end
          will_retry = retryable_response?(response)
          log_failure(
            "Encountered non-2xx HTTP code #{response.code}",
            :response_code => response.code,
            :url => url,
            :event => event,
            :will_retry => will_retry
          )

          if will_retry
            yield :retry, event, attempt
          else
            yield :failure, event, attempt
          end
        else
          yield :success, event, attempt
        end
      rescue => e
        # Shouldn't ever happen
        @logger.error("Unexpected error in request success!",
          :class => e.class.name,
          :message => e.message,
          :backtrace => e.backtrace)
      end
    end

    request.on_failure do |exception|
      begin
        will_retry = retryable_exception?(exception)
        log_failure("Could not fetch URL",
                    :url => url,
                    :method => @http_method,
                    :body => body,
                    :headers => headers,
                    :message => exception.message,
                    :class => exception.class.name,
                    :backtrace => exception.backtrace,
                    :will_retry => will_retry
        )
        if will_retry
          yield :retry, event, attempt
        else
          yield :failure, event, attempt
        end
      rescue => e
        # Shouldn't ever happen
        @logger.error("Unexpected error in request failure!",
          :class => e.class.name,
          :message => e.message,
          :backtrace => e.backtrace)
        end
    end
  end

  def close
    @timer.cancel
    client.close
  end

  private

  def response_success?(response)
    code = response.code
    return true if @ignorable_codes && @ignorable_codes.include?(code)
    return code >= 200 && code <= 299
  end

  def retryable_response?(response)
    @retryable_codes.include?(response.code)
  end

  def retryable_exception?(exception)
    RETRYABLE_MANTICORE_EXCEPTIONS.any? {|me| exception.is_a?(me) }
  end

  # This is split into a separate method mostly to help testing
  def log_failure(message, opts)
    puts message
    @logger.error("[HTTP Output Failure] #{message}", opts)
  end

  
  def request_async_background(request)
    @method ||= client.executor.java_method(:submit, [java.util.concurrent.Callable.java_class])
    @method.call(request)
  end

  # Format the HTTP body
  def event_body(event)
    # TODO: Create an HTTP post data codec, use that here
    if @format == "json"
      documents = []
      document = event.to_hash()
      documents.push(document)
      LogStash::Json.dump(documents)
    elsif @format == "message"
      event.sprintf(@message)
    else
      encode(map_event(event))
    end
  end

  def convert_mapping(mapping, event)
    if mapping.is_a?(Hash)
      mapping.reduce({}) do |acc, kv|
        k, v = kv
        acc[k] = convert_mapping(v, event)
        acc
      end
    elsif mapping.is_a?(Array)
      mapping.map { |elem| convert_mapping(elem, event) }
    else
      event.sprintf(mapping)
    end
  end

  def map_event(event)
    if @mapping
      convert_mapping(@mapping, event)
    else
      event.to_hash
    end
  end

  def event_headers(event)
    headers = custom_headers(event) || {}
    headers["Content-Type"] = @content_type
    #headers["Authtoken"] = @auth_token
    headers["Authtoken"] = @auth_token
    headers
  end

  def custom_headers(event)
    return nil unless @headers

    @headers.reduce({}) do |acc,kv|
      k,v = kv
      acc[k] = event.sprintf(v)
      acc
    end
  end

  #TODO Extract this to a codec
  def encode(hash)
    return hash.collect do |key, value|
      CGI.escape(key) + "=" + CGI.escape(value.to_s)
    end.join("&")
  end


  def validate_format!
    if @format == "message"
      if @message.nil?
        raise "message must be set if message format is used"
      end

      if @content_type.nil?
        raise "content_type must be set if message format is used"
      end

        unless @mapping.nil?
          @logger.warn "mapping is not supported and will be ignored if message format is used"
      end
    end
  end
end
