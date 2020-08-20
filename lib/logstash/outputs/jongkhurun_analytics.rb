# encoding: utf-8
require "logstash/outputs/base"
require "logstash/namespace"
# require "logstash/json"
# require "uri"
require "logstash/plugin_mixins/http_client"
require "stud/buffer"
require "zlib"
require "base64"
require "json"

# An jongkhurun_analytics output that does nothing.
class LogStash::Outputs::JongkhurunAnalytics < LogStash::Outputs::Base
  include LogStash::PluginMixins::HttpClient

  config_name "jongkhurun_analytics"

  concurrency :single

  # 数据接收地址, 可配置多个
  config :url, :validate => :array, :required => :true

  # 数据的项目
  config :project, :validate => :string

  # 触发 flush 间隔
  config :flush_interval_sec, :validate => :number, :default => 2

  # 批次最大 record 数量
  config :flush_batch_size, :validate => :number, :default => 100

  # 数据中用做 hash 的值
  config :hash_filed, :validate => :array

  # 开启 filebeat 状态记录
  config :enable_filebeat_status_report, :validate => :boolean, :default => true

  PLUGIN_VERSION = "0.1.0"

  public
  def register
    @logger.info("Registering jongkhurun_analytics Output",
                 :version => PLUGIN_VERSION,
                 :url => @url,
                 :flush_interval_sec => @flush_interval_sec,
                 :flush_batch_size => @flush_batch_size,
                 :hash_filed => @hash_filed,
                 :enable_filebeat_status_report => @enable_filebeat_status_report
    )

    http_client_config = client_config
    http_client_config[:user_agent] = "JongkhurunAnalytics Logstash Output Plugin " + PLUGIN_VERSION
    @client = Manticore::Client.new(http_client_config)
    @buffer_items = []
    @receive_count = 0
    @parse_error_count = 0
    @last_report_time = Time.now
    @last_report_count = 0
    @url.each_index do |i|
      option = {
          :flush_batch_size => @flush_batch_size,
          :flush_interval_sec => @flush_interval_sec,
          :client => @client,
          :url_list => @url,
          :index => i,
          :logger => @logger
      }
      buffer_item = BufferItem.new(option)
      @buffer_items << buffer_item
    end

    @recent_filebeat_status = {} if @enable_filebeat_status_report
    @report_thread = Thread.new do
      loop do
        sleep 60
        report
      end
    end

  end # def register

  public
  def receive(event)
    return "Event received"
  end # def event
end # class LogStash::Outputs::JongkhurunAnalytics


class BufferItem
  include Stud::Buffer

  attr_accessor :buffer_state
  attr_accessor :url_send_count

  def initialize(option = {})
    @client = option[:client]
    @url_send_count = {}
    url_list = option[:url_list]
    url_list.each do |url|
      @url_send_count[url] = 0
    end
    init_url_list(url_list, option[:index])
    @logger = option[:logger]

    buffer_config = {
        :max_items => option[:flush_batch_size],
        :max_interval => option[:flush_interval_sec],
        :logger => @logger
    }
    buffer_initialize(buffer_config)
  end

  def do_send(form_data, url)
    begin
      response = @client.post(url, :params => form_data).call
      if response.code != 200
        @logger.warn("Send failed, code: #{response.code}, body: #{response.body}")
        return false
      end
    rescue => e
      @logger.warn("Send failed", :exception => e.class.name, :backtrace => e.backtrace)
      return false
    end
    true
  end

  public
  # 数据被 Gzip > Base64 后尝试发送
  # 如果当前 url 发送失败, 会尝试获取列表中下一个地址进行发送, 发送失败的 url 在 3 秒内不会再尝试发送
  # 如果所有的 url 都被标记为发送失败, sleep 5 秒后重新获取
  def flush(events, final)
    wio = StringIO.new("w")
    gzip_io = Zlib::GzipWriter.new(wio)
    gzip_io.write(events.to_json)
    gzip_io.close
    data = Base64.strict_encode64(wio.string)
    form_data = {"data_list" => data, "gzip" => 1}

    url_item = obtain_url

    until do_send(form_data, url_item[:url])
      last_url = url_item[:url]
      # 将发送失败的 url 标记为不可用
      disable_url(url_item)
      url_item = obtain_url
      @logger.warn("Send failed, retry send data to another url", :last_url => last_url, :retry_url => url_item[:url])
    end
    @url_send_count[url_item[:url]] += events.length
  end

  private
  # 把当前 buffer 用的 url 从 list 的 0 索引开始依次放入, 方便在 obtain_url 遍历
  def init_url_list(urls, start_index)
    @url_list = []
    index = start_index
    loop do
      @url_list << {
          :url => urls[index],
          :ok? => true,
          :fail_time => Time.now
      }
      index = (index + 1) % urls.length
      break if index == start_index
    end
  end

  private
  def obtain_url
    while true do
      @url_list.each do |url_item|
        return url_item if url_item[:ok?]
        if Time.now - url_item[:fail_time] > 3
          url_item[:ok] = true
          return url_item
        end
      end
      @logger.warn("All url disable, sleep 5 sec")
      sleep 5
    end
  end

  private
  def disable_url(url_item)
    url_item[:ok?] = false
    url_item[:fail_time] = Time.now
  end
end
