require 'json'
require 'net/http'
require 'open3'

url = URI(ENV.fetch('ZABBIX_URL', 'http://127.0.0.1:8080/api_jsonrpc.php'))
vm = ENV.fetch('PICO_VM', 'picoruby')
sender_host = ENV.fetch('ZABBIX_SENDER_HOST', '127.0.0.1')
sender_port = Integer(ENV.fetch('ZABBIX_SENDER_PORT', '10051'))
template_path = File.expand_path('../templates/picoruby_telemetry.yaml', __dir__)

def api(url, method, params, token = nil)
  headers = { 'Content-Type' => 'application/json-rpc' }
  headers['Authorization'] = "Bearer #{token}" if token
  response = Net::HTTP.post(url, JSON.generate({ jsonrpc: '2.0', method: method, params: params, id: 1 }), headers)
  raise "HTTP #{response.code}" unless response.code == '200'
  body = JSON.parse(response.body)
  raise "#{method}: #{body['error']}" if body['error']
  body['result']
end

def run_vm(vm, code)
  out, err, status = Open3.capture3(vm, '-e', code)
  raise "VM failed: #{out} #{err}" unless status.success?
  out
end

def wait_for_sensor_trigger(url, token, host_id, expected)
  30.times do
    triggers = api(url, 'trigger.get', { hostids: host_id, output: ['triggerid', 'description', 'value'] }, token)
    sensor = triggers.find { |trigger| trigger['description'] == 'PicoRuby sensor check critical' }
    return if sensor && sensor['value'] == expected
    sleep 2
  end
  raise "sensor trigger did not reach state #{expected}"
end

puts "Zabbix API: #{api(url, 'apiinfo.version', {})}"
token = api(url, 'user.login', { username: ENV.fetch('ZABBIX_USER', 'Admin'),
                                 password: ENV.fetch('ZABBIX_PASSWORD', 'zabbix') })
rules = { 'template_groups' => { 'createMissing' => true, 'updateExisting' => true },
          'templates' => { 'createMissing' => true, 'updateExisting' => true },
          'items' => { 'createMissing' => true, 'updateExisting' => true },
          'triggers' => { 'createMissing' => true, 'updateExisting' => true } }
raise 'template import failed' unless api(url, 'configuration.import', { format: 'yaml', source: File.read(template_path), rules: rules }, token)
template = api(url, 'template.get', { output: ['templateid'], filter: { host: 'PicoRuby Telemetry' } }, token).first
raise 'template missing' unless template
container_group = api(url, 'hostgroup.get', { output: ['groupid', 'name'] }, token).find { |group| group['name'] == 'Linux servers' }
raise 'host group missing' unless container_group
host_name = "picoruby-telemetry-it-#{Process.pid}-#{Time.now.to_i}"
host_id = api(url, 'host.create', { host: host_name, groups: [{ groupid: container_group['groupid'] }],
                                  templates: [{ templateid: template['templateid'] }] }, token)['hostids'].first
raise 'host creation failed' unless host_id
begin
  system('docker', 'exec', 'tools-zabbix-server-1', 'zabbix_server', '-R', 'config_cache_reload', out: File::NULL, err: File::NULL)
  sender = <<~CODE
    require 'telemetry'
    require 'telemetry-transport'
    require 'telemetry-zabbix'
    now = Time.now.to_i
    records = [PicoTelemetry::Record.log(PicoTelemetry::Severity::INFO, 'live log'),
               PicoTelemetry::Record.metric('temperature', 23.5),
               PicoTelemetry::Record.check('sensor', :critical, 'live check')]
    i = 0
    while i < records.size
      records[i].epoch_sec = now
      i += 1
    end
    driver = PicoTelemetry::Zabbix::Driver.new(server: #{sender_host.inspect}, port: #{sender_port}, host: #{host_name.inspect}, check_message_key: true)
    result = driver.deliver(records, records.size)
    raise "sender: \#{result.status} \#{result.error}" unless result.status == :ok
  CODE
  sent = false
  12.times do |attempt|
    begin
      run_vm(vm, sender)
      sent = true
      break
    rescue RuntimeError => error
      sleep 5
      raise error if attempt == 11
    end
  end
  raise 'sender unavailable' unless sent
  puts 'sender: ok'
  wait_for_sensor_trigger(url, token, host_id, '1')
  puts 'sensor trigger fired: ok'

  history = <<~CODE
    require 'telemetry'
    require 'telemetry-transport'
    require 'telemetry-zabbix'
    now = Time.now.to_i
    records = [PicoTelemetry::Record.log(PicoTelemetry::Severity::INFO, 'history log'),
               PicoTelemetry::Record.metric('temperature', 24.5),
               PicoTelemetry::Record.check('sensor', :warning, 'history check')]
    i = 0
    while i < records.size
      records[i].epoch_sec = now
      records[i].nsec = 100
      i += 1
    end
    driver = PicoTelemetry::Zabbix::Driver.new(mode: :history_push,
      api_url: #{url.to_s.inspect}, api_token: #{token.inspect},
      host: #{host_name.inspect}, check_message_key: true)
    result = driver.deliver(records, records.size)
    raise "history: \#{result.status} \#{result.error}" unless result.status == :ok
  CODE
  run_vm(vm, history)
  puts 'history.push: ok'
  wait_for_sensor_trigger(url, token, host_id, '0')
  puts 'sensor trigger recovered: ok'

  items = api(url, 'item.get', { hostids: host_id, output: ['itemid', 'key_', 'value_type'] }, token)
  expected = { 'picoruby.log' => 2, 'picoruby.metric[temperature]' => 0,
               'picoruby.check[sensor]' => 3, 'picoruby.check.msg[sensor]' => 4 }
  expected.each do |key, type|
    item = items.find { |candidate| candidate['key_'] == key }
    raise "missing item #{key}" unless item && item['value_type'].to_i == type
    expected_values = case key
                      when 'picoruby.log' then ['live log', 'history log']
                      when 'picoruby.metric[temperature]' then ['23.5', '24.5']
                      when 'picoruby.check[sensor]' then ['2', '1']
                      else ['live check', 'history check']
                      end
    values = []
    12.times do
      entries = api(url, 'history.get', { history: type, itemids: item['itemid'], output: 'extend', limit: 10 }, token)
      values = entries.map { |entry| entry['value'].to_s }
      break if expected_values.all? { |value| values.any? { |actual| actual.include?(value) } }
      sleep 2
    end
    expected_values.each do |value|
      raise "missing #{key} value #{value}" unless values.any? { |actual| actual.include?(value) }
    end
  end
  puts 'stored log, metric, check, and check message: ok'

  bad_sender = <<~CODE
    require 'telemetry'
    require 'telemetry-transport'
    require 'telemetry-zabbix'
    record = PicoTelemetry::Record.metric('missing', 1)
    record.epoch_sec = Time.now.to_i
    driver = PicoTelemetry::Zabbix::Driver.new(server: #{sender_host.inspect}, port: #{sender_port}, host: #{host_name.inspect})
    result = driver.deliver([record], 1)
    raise "sender rejection: \#{result.status} \#{result.accepted}" unless result.status == :partial && result.accepted == 0
  CODE
  run_vm(vm, bad_sender)
  puts 'sender rejected unknown item: ok'

  bad_history = <<~CODE
    require 'telemetry'
    require 'telemetry-transport'
    require 'telemetry-zabbix'
    record = PicoTelemetry::Record.metric('missing', 1)
    record.epoch_sec = Time.now.to_i
    driver = PicoTelemetry::Zabbix::Driver.new(mode: :history_push,
      api_url: #{url.to_s.inspect}, api_token: #{token.inspect}, host: #{host_name.inspect})
    result = driver.deliver([record], 1)
    raise "history rejection: \#{result.status} \#{result.rejected_indexes}" unless result.status == :partial && result.rejected_indexes == [0]
  CODE
  run_vm(vm, bad_history)
  puts 'history.push rejected unknown item: ok'
ensure
  api(url, 'host.delete', [host_id], token)
end
