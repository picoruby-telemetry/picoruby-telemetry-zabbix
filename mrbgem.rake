MRuby::Gem::Specification.new('picoruby-telemetry-zabbix') do |spec|
  spec.license = 'MIT'
  spec.author = 'PicoTelemetry contributors'
  spec.summary = 'Zabbix sender and history.push driver for PicoTelemetry'
  spec.version = '0.1.0.dev'
  spec.add_dependency 'picoruby-telemetry'
  spec.add_dependency 'picoruby-telemetry-transport'
  spec.add_dependency 'picoruby-json'
end
