# Set up Zabbix

Create a host in Zabbix 7.0 or later whose technical host name matches the driver's `host` setting. Import `templates/picoruby_telemetry.yaml` and link it to the host, or create the following Zabbix trapper items manually. The template follows the Zabbix 7.0 export format, but its import has not been tested against a live server.

| Item key | Value type |
| --- | --- |
| `picoruby.log` | Log |
| `picoruby.metric[temperature]` | Numeric float |
| `picoruby.check[sensor]` | Numeric integer |
| `picoruby.check.msg[sensor]` | Text, when `check_message_key: true` |
| `picoruby.heartbeat` | Numeric integer, when `heartbeat_sec` is enabled |

Sender mode uses TCP port 10051. It sends plaintext, so use a trusted LAN or a nearby proxy. Restrict source addresses with each item's **Allowed hosts** setting. After creating items, allow time for the Zabbix configuration cache to update.

Set `check_message_key: true` on the driver to send check descriptions to the text item. Call `PicoTelemetry.flush` on the device, then inspect **Latest data** in Zabbix.

For `history.push`, issue an API token for a user with read access to the target host and permission to call `history.push`. Include the web frontend's source IP in **Allowed hosts**. Pass `mode: :history_push`, `api_url`, and `api_token` to the driver. Keep the token out of source files.

If the response reports failed items, check the technical host name, item keys, value types, and **Allowed hosts**. Zabbix sender responses do not identify rejected item indexes, so partially rejected items are not retried.
