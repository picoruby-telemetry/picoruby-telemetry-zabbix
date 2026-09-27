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

## 日本語

Zabbix sender と `history.push` に対応する送信ドライバーです。開発版です。
コアと通信層も PicoRuby ビルドに追加してください。sender は平文通信です。
ホスト上の両 VM で試験済みですが、実際の Zabbix サーバーへの送信とテンプレートのインポートは未検証です。

MIT License.
