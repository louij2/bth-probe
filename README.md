# bth-probe

Is MikroTik **Back To Home** (BTH) usable as the way in when Tailscale is down?

The container connects as one BTH user through the MikroTik relay (`*.vpn.mynetname.net`),
the same path a phone on LTE uses when the router is behind NAT. Every `PROBE_INTERVAL`
seconds it checks from inside the tunnel:

| check | passes when |
|---|---|
| `ping` | the router's tunnel address (192.168.216.1) answers |
| `handshake` | the last WireGuard handshake is under 5 minutes old |
| `dns` | each of `DNS_NAMES` resolves to a **private** address via the BTH resolver |
| `http` | each of `HTTP_TARGETS` answers HTTPS with any status code |

Only `ROUTES` (default `192.168.216.0/24,10.0.0.0/16`) go into `wg0`, so a pass really went
through the tunnel. Metrics, on `:9841/metrics`:

- `bth_probe_up{host}`: 1 if every check passed on the last run.
- `bth_probe_check_success{host,check,target}`
- `bth_probe_handshake_age_seconds{host}`: -1 means never.
- `bth_probe_last_run_timestamp_seconds{host}`, `bth_probe_run_duration_seconds{host}`

The Docker healthcheck only says the loop is running. A BTH outage shows up in the metrics
and the alert, and does not restart the container.

## When BTH is revoked or rotated

A revoke **deletes every BTH user** and changes the server key **and the port** (5630
became 17007 on 2026-11-18). The probe then fails, and the alert fires. To fix it:

1. Recreate the probe user on the router (allow-lan=yes) with the private key from the env-file.
2. Update the template's `BTH_SERVER_PUBLIC_KEY` (`/ip cloud` vpn-public-key),
   `BTH_ENDPOINT` (vpn-dns-name:vpn-port), and `BTH_ADDRESS` (the user's client-address).
3. Recreate the container: `tpl-recreate.sh bth-probe`.

## First install (tower)

1. A BTH user for the probe on the router, allow-lan=yes. Homelab: `probe-1005-monitor`
   on the CRS326.
2. `/mnt/user/appdata/bth-probe/.env`, mode 0600: `BTH_PRIVATE_KEY=...`
3. `cp unraid/my-bth-probe.xml /boot/config/plugins/dockerMan/templates-user/` and fill in
   the three `BTH_*` values.
4. `docker build` and push (`deploy.sh` does both). Then create the container from the template:
   `cd /usr/local/emhttp && eval "$(php /mnt/user/appdata/compose-to-templates/tpl-cmd.php /boot/config/plugins/dockerMan/templates-user/my-bth-probe.xml)"`,
   add it to `/var/lib/docker/unraid-autostart`, and put it in the Exporters folder.
5. Prometheus job `bth-probe` → `10.0.0.24:9841`, with `fallback_scrape_protocol: PrometheusText0.0.4`.
   busybox httpd sends no Content-Type for `/metrics`, and Prometheus 3 refuses the scrape without it.

Updates after that: `./deploy.sh`.

Alerts: louij2/grafana-homelab `scripts/add_bth_probe_alerts.py`, group "Back To Home"
(`terraform/alert-rules-back-to-home.tf`).

Needs `--cap-add=NET_ADMIN` and the host's `wireguard` kernel module (Unraid has it).

ADO Homelab #1005. Runbook: homelab-runbooks `docs/runbooks/bth-fallback.md`.
