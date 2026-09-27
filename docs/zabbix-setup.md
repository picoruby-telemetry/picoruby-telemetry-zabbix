# Set up Zabbix

Create a host in Zabbix 7.0 or later whose technical host name matches the driver's `host` setting. Import `templates/picoruby_telemetry.yaml` and link it to the host, or create the following Zabbix trapper items manually. The template imported successfully into Zabbix 7.0.31 and 7.4.15.

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

## Local integration check

Build PicoRuby with this gem, the core gem, and the transport gem, then run:

```sh
docker compose -f tools/docker-compose.zabbix.yml up -d
PICO_VM=/path/to/picoruby/bin/picoruby ruby tools/live_test.rb
docker compose -f tools/docker-compose.zabbix.yml down -v
```

The check imports the template, creates a temporary host, sends via both modes, verifies saved history and sensor trigger transitions, and deletes the host. It uses the Compose instance's default `Admin`/`zabbix` credentials. Set `ZABBIX_URL`, `ZABBIX_USER`, `ZABBIX_PASSWORD`, `ZABBIX_SENDER_HOST`, and `ZABBIX_SENDER_PORT` to use another instance. The Compose ports listen on localhost only.

Set `ZABBIX_VERSION=7.4` on the `docker compose up` command to run the same check against Zabbix 7.4. Use a fresh Compose database when switching versions.
