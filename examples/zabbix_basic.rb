# Gems: picoruby-telemetry, picoruby-telemetry-transport, picoruby-telemetry-zabbix.
# Set ZABBIX_SERVER and ZABBIX_HOST; create matching trapper items first.
require 'telemetry'
require 'telemetry-transport'
require 'telemetry-zabbix'

config = PicoTelemetry::Config.new
config.device_name = ENV['ZABBIX_HOST']
driver = PicoTelemetry::Zabbix::Driver.new(server: ENV['ZABBIX_SERVER'], host: config.device_name)
config.add_sink(:zabbix, driver)
PicoTelemetry.setup(config)
PicoTelemetry.info('boot completed')
PicoTelemetry.metric('temperature', 23.5)
PicoTelemetry.check('sensor', :ok, 'ready')
PicoTelemetry.flush
