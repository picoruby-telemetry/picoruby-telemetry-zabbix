# PicoTelemetry Zabbix driver

Pure Ruby Zabbix sender and `history.push` driver. Development version.
Requires the core and transport repositories in the same PicoRuby build.
Load them with `require 'telemetry'`, `require 'telemetry-transport'`, and
`require 'telemetry-zabbix'` in that order.

```ruby
require 'telemetry'
require 'telemetry-transport'
require 'telemetry-zabbix'
driver = PicoTelemetry::Zabbix::Driver.new(server: '192.168.1.10', host: 'pico-01')
config = PicoTelemetry::Config.new
config.add_sink(:zabbix, driver)
PicoTelemetry.setup(config)
PicoTelemetry.metric('temperature', 23.5)
PicoTelemetry.flush
```

The sender protocol is plaintext. Use it on a trusted LAN or through a
nearby proxy. `history.push` supports HTTPS with an API token.

Live Zabbix delivery and template import have not been tested. MIT License.
