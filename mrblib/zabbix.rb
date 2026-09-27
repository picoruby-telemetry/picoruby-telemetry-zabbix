require 'json'

# FemtoRuby cannot read module instance variables used by JSON.use_regexp?.
if RUBY_ENGINE == 'mruby/c'
  module JSON
    def self.use_regexp?; false; end
  end
end

class PicoTelemetry
  module Zabbix
    class KeyMapper
      def initialize(log_key: 'picoruby.log', metric_key: nil, check_key: nil, check_message_key: nil)
        @log_key = log_key
        @metric_key = metric_key
        @check_key = check_key
        @check_message_key = check_message_key
      end
      def key(record)
        case record.kind
        when :log then @log_key
        when :metric then record.name == 'heartbeat' ? 'picoruby.heartbeat' : (@metric_key.is_a?(Proc) ? @metric_key.call(record.name) : "picoruby.metric[#{record.name}]")
        else @check_key.is_a?(Proc) ? @check_key.call(record.name) : "picoruby.check[#{record.name}]"
        end
      end
      def value(record, numeric = false)
        case record.kind
        when :metric then numeric ? record.value : record.value.to_s
        when :check
          value = { ok: 0, warning: 1, critical: 2, unknown: 3 }[record.status]
          numeric ? value : value.to_s
        else
          text = "[#{Severity.label(record.severity)}] #{record.name}: #{record.message}"
          append_attrs(text, record.static_attrs)
          append_attrs(text, record.attrs)
          text
        end
      end
      def message_key(record)
        return nil unless record.kind == :check && record.message && @check_message_key
        return "picoruby.check.msg[#{record.name}]" if @check_message_key == true
        return @check_message_key.call(record.name) if @check_message_key.is_a?(Proc)
        @check_message_key.to_s
      end
      private
      def append_attrs(text, attrs)
        return unless attrs
        keys = attrs.keys
        i = 0
        while i < keys.size
          key = keys[i]
          text << " #{key}=#{attrs[key]}"
          i += 1
        end
      end
    end

    module Codec
      def self.le32(value)
        text = ''
        i = 0
        while i < 4
          text << ((value >> (8 * i)) & 255).chr
          i += 1
        end
        text
      end
      def self.fields(batch, count, host, mapper, numeric = false, indexes = nil)
        data = []
        seen = {}
        i = 0
        while i < count
          record = batch[i]
          append(data, seen, host, mapper.key(record), mapper.value(record, numeric), record)
          indexes << i if indexes
          message_key = mapper.message_key(record)
          if message_key
            append(data, seen, host, message_key, record.message, record)
            indexes << i if indexes
          end
          i += 1
        end
        data
      end
      def self.append(data, seen, host, key, value, record)
        item = { 'host' => host, 'key' => key, 'value' => value }
        if record.epoch_sec
          second = record.epoch_sec
          identity = "#{key}:#{second}"
          nsec = record.nsec
          previous = seen[identity]
          nsec = previous + 1 if previous && nsec <= previous
          seen[identity] = nsec
          item['clock'] = second
          item['ns'] = nsec
        end
        data << item
      end
    end

    module SenderCodec
      def self.encode(batch, count, host, mapper = KeyMapper.new, fields = nil)
        JSON.generate({ 'request' => 'sender data', 'data' => fields || Codec.fields(batch, count, host, mapper) })
      end
      def self.frame(body)
        'ZBXD' + 1.chr + Codec.le32(body.bytesize) + Codec.le32(0) + body
      end
    end

    module SenderResponseParser
      def self.read_response(io, tcp, max_bytes = 4096)
        header = tcp.read_exact(io, 13)
        raise Transport::ProtocolError, 'bad sender magic' unless header.byteslice(0, 4) == 'ZBXD'
        raise Transport::ProtocolError, 'unsupported sender flags' unless header.getbyte(4) == 1
        raise Transport::ProtocolError, 'oversize sender response' unless header.byteslice(8, 5) == 0.chr * 5
        length = header.getbyte(5) | (header.getbyte(6) << 8) | (header.getbyte(7) << 16)
        raise Transport::ProtocolError, 'oversize sender response' if length > max_bytes
        tcp.read_exact(io, length)
      end
      def self.parse(body, count)
        data = JSON.parse(body)
        return Result.drop('sender rejected request') unless data['response'] == 'success'
        info = data['info'] || ''
        parts = info.split('; ')
        failed = nil
        i = 0
        while i < parts.size
          pair = parts[i].split(': ')
          failed = pair[1].to_i if pair[0] == 'failed'
          i += 1
        end
        return Result.retry('missing sender failed count') unless failed && failed >= 0 && failed <= count
        failed == 0 ? Result.ok(count) : Result.partial(count - failed)
      rescue StandardError => error
        Result.retry(error)
      end
    end

    module HistoryPushCodec
      def self.encode(batch, count, host, id, mapper = KeyMapper.new, fields = nil)
        JSON.generate({ 'jsonrpc' => '2.0', 'method' => 'history.push',
                        'params' => fields || Codec.fields(batch, count, host, mapper, true), 'id' => id })
      end
    end

    module HistoryPushResponseParser
      def self.parse(body, count)
        data = JSON.parse(body)
        return Result.fatal('history.push API error') if data['error']
        result = data['result']
        return Result.retry('invalid history.push response') unless result && result['response'] == 'success'
        rows = result['data']
        return Result.retry('invalid history.push data') unless rows && rows.size == count
        rejected = []
        i = 0
        while i < count
          rejected << i if rows[i]['error']
          i += 1
        end
        rejected.empty? ? Result.ok(count) : Result.partial(count - rejected.size, rejected)
      rescue StandardError => error
        Result.retry(error)
      end
    end

    class Driver < PicoTelemetry::Driver::Base
      def initialize(mode: :sender, server: nil, port: 10051, host: nil,
                     api_url: nil, api_token: nil, transport: nil,
                     ca_file: nil, verify_tls: true, heartbeat_sec: 0,
                     connect_timeout_ms: 3000, io_timeout_ms: 5000,
                     batch_max_records: 50, batch_max_bytes: 8192,
                     log_key: 'picoruby.log', metric_key: nil, check_key: nil, check_message_key: nil)
        @mode, @server, @port, @host = mode, server, port, host
        @api_url, @api_token, @transport = api_url, api_token, transport
        @ca_file, @verify_tls = ca_file, verify_tls
        @heartbeat_sec, @last_heartbeat, @started_ms = heartbeat_sec, nil, nil
        @connect_timeout_ms, @io_timeout_ms = connect_timeout_ms, io_timeout_ms
        @batch_max_records, @batch_max_bytes = batch_max_records, batch_max_bytes
        @mapper = KeyMapper.new(log_key: log_key, metric_key: metric_key,
                                check_key: check_key, check_message_key: check_message_key)
        @id = 0
      end
      def name; 'zabbix'; end
      def supports?(kind); kind == :log || kind == :metric || kind == :check; end
      def batch_max_records; @batch_max_records; end
      def batch_max_bytes; @batch_max_bytes; end
      def estimate_bytes(record)
        bytes = 80 + record.name.bytesize + (record.message ? record.message.bytesize : 20)
        bytes += 80 + record.name.bytesize + record.message.bytesize if @mapper.message_key(record)
        bytes
      end
      def ttl_sec(kind); 86_400; end
      def open
        return Result.fatal('Zabbix host is required') unless @host && !@host.empty?
        if @mode == :sender
          return Result.fatal('Zabbix server is required') unless @server && !@server.empty?
        elsif @mode == :history_push
          return Result.fatal('Zabbix API URL and token are required') unless @api_url && @api_token
        else
          return Result.fatal('unknown Zabbix mode')
        end
        Result.ok(0)
      end
      def deliver(batch, count)
        indexes = []
        fields = Codec.fields(batch, count, @host, @mapper, @mode == :history_push, indexes)
        if @mode == :sender
          tcp = @transport || Transport::TCP.new(host: @server, port: @port,
                    connect_timeout_ms: @connect_timeout_ms, io_timeout_ms: @io_timeout_ms)
          body = SenderCodec.encode(batch, count, @host, @mapper, fields)
          response = tcp.exchange(SenderCodec.frame(body)) do |io|
            SenderResponseParser.read_response(io, tcp)
          end
          result = SenderResponseParser.parse(response, fields.size)
          if result.status == :ok
            Result.ok(count)
          elsif result.status == :partial
            rejected = fields.size - result.accepted
            Result.partial([count - rejected, 0].max)
          else
            result
          end
        else
          @id += 1
          separator = @api_url.rindex('/')
          base = @api_url.byteslice(0, separator)
          path = @api_url.byteslice(separator, @api_url.bytesize - separator)
          http = @transport || Transport::HTTP.new(base_url: base, ca_file: @ca_file,
                                                    verify: @verify_tls, open_timeout_ms: @connect_timeout_ms,
                                                    read_timeout_ms: @io_timeout_ms)
          headers = { 'Content-Type' => 'application/json-rpc', 'Authorization' => "Bearer #{@api_token}" }
          response = http.post(path, HistoryPushCodec.encode(batch, count, @host, @id, @mapper, fields), headers)
          classification = Transport.classify_http_status(response.status)
          return Result.retry('Zabbix HTTP unavailable') if classification == :retry
          return Result.fatal('Zabbix API authentication failed') if classification == :fatal
          return Result.drop('Zabbix HTTP rejected request') if classification == :drop
          result = HistoryPushResponseParser.parse(response.body, fields.size)
          return Result.ok(count) if result.status == :ok
          if result.status == :partial
            rejected = {}
            i = 0
            while i < result.rejected_indexes.size
              rejected[indexes[result.rejected_indexes[i]]] = true
              i += 1
            end
            records = rejected.keys
            return Result.partial(count - records.size, records)
          end
          result
        end
      rescue Transport::UnsupportedError => error
        Result.fatal(error)
      rescue StandardError => error
        Result.retry(error)
      end
      def on_tick(now_sec, emitter)
        return if @heartbeat_sec <= 0
        now_ms = emitter.clock.mono_ms
        @started_ms ||= now_ms
        if !@last_heartbeat || now_ms - @last_heartbeat >= @heartbeat_sec * 1000
          @last_heartbeat = now_ms
          emitter.emit(Record.metric('heartbeat', (now_ms - @started_ms) / 1000))
        end
      end
    end
  end
end
