class ZabbixTest < Picotest::Test
  def test_heartbeat_uses_uptime_key_and_value
    clock = PicoTelemetry::FakeClock.new(1_790_000_000)
    emitter = HeartbeatEmitter.new(clock)
    driver = PicoTelemetry::Zabbix::Driver.new(host: 'device', server: 'localhost', heartbeat_sec: 60)
    driver.on_tick(clock.now_sec, emitter)
    assert_equal(0, emitter.records[0].value)
    assert_equal('picoruby.heartbeat', PicoTelemetry::Zabbix::KeyMapper.new.key(emitter.records[0]))
    clock.advance(60_000)
    driver.on_tick(clock.now_sec, emitter)
    assert_equal(60, emitter.records[1].value)
  end

  class HeartbeatEmitter
    attr_reader :clock, :records
    def initialize(clock); @clock, @records = clock, []; end
    def emit(record); @records << record; end
  end
  def test_sender_frame_and_response
    assert(PicoTelemetry.const_defined?(:Zabbix))
    return unless PicoTelemetry.const_defined?(:Zabbix)
    codec = PicoTelemetry::Zabbix::SenderCodec
    frame = codec.frame('x' * 4660)
    assert_equal([90, 66, 88, 68, 1, 52, 18, 0, 0, 0, 0, 0, 0], frame.byteslice(0, 13).bytes)
    response = PicoTelemetry::Zabbix::SenderResponseParser.parse('{"response":"success","info":"processed: 2; failed: 1; total: 3; seconds spent: 0.01"}', 3)
    assert_equal(:partial, response.status)
    assert_equal(2, response.accepted)
  end

  def test_sender_rejects_high_length_bytes
    header = 'ZBXD' + 1.chr + 1.chr + (0.chr * 6) + 1.chr
    tcp = PicoTelemetry::Transport::TCP.new(host: 'localhost', port: 1)
    assert_raise(PicoTelemetry::Transport::ProtocolError) do
      PicoTelemetry::Zabbix::SenderResponseParser.read_response(BufferIO.new(header + 'x'), tcp)
    end
  end

  class BufferIO
    def initialize(data); @data = data; end
    def read(count)
      part = @data.byteslice(0, count)
      @data = @data.byteslice(count, @data.bytesize - count)
      part
    end
  end

  def test_history_partial
    assert(PicoTelemetry.const_defined?(:Zabbix))
    return unless PicoTelemetry.const_defined?(:Zabbix)
    result = PicoTelemetry::Zabbix::HistoryPushResponseParser.parse('{"result":{"response":"success","data":[{}, {"error":"bad key"}, {}]}}', 3)
    assert_equal(:partial, result.status)
    assert_equal([1], result.rejected_indexes)
  end

  def test_check_message_item_and_record_count
    check = PicoTelemetry::Record.check('sensor', :warning, 'low voltage')
    check.epoch_sec = 1_790_000_000
    mapper = PicoTelemetry::Zabbix::KeyMapper.new(check_message_key: true)
    fields = PicoTelemetry::Zabbix::Codec.fields([check], 1, 'device', mapper)
    assert_equal(2, fields.size)
    assert_equal('picoruby.check.msg[sensor]', fields[1]['key'])
    assert_equal('low voltage', fields[1]['value'])
    mock = SenderMock.new
    driver = PicoTelemetry::Zabbix::Driver.new(host: 'device', server: 'localhost',
      transport: mock, check_message_key: true)
    assert_equal(:ok, driver.deliver([check], 1).status)
    assert_equal(2, JSON.parse(mock.payload)['data'].size)
  end

  def test_history_rejection_maps_message_to_check
    mock = PicoTelemetry::Transport::Mock.new
    mock.enqueue_response(200, '{"result":{"response":"success","data":[{}, {"error":"missing item"}]}}')
    driver = PicoTelemetry::Zabbix::Driver.new(mode: :history_push, host: 'device',
      api_url: 'https://localhost/api_jsonrpc.php', api_token: 'token',
      transport: mock, check_message_key: true)
    check = PicoTelemetry::Record.check('sensor', :warning, 'low voltage')
    check.epoch_sec = 1_790_000_000
    result = driver.deliver([check], 1)
    assert_equal(:partial, result.status)
    assert_equal(0, result.accepted)
    assert_equal([0], result.rejected_indexes)
  end

  class SenderMock
    attr_reader :payload
    def exchange(request)
      @payload = request.byteslice(13, request.bytesize - 13)
      '{"response":"success","info":"processed: 2; failed: 0; total: 2; seconds spent: 0.01"}'
    end
  end
end
