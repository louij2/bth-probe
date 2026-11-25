#!/bin/sh
# bth-probe: is MikroTik Back To Home (BTH) usable as the way in when Tailscale is down?
#
# Brings up a kernel WireGuard interface as one BTH user, through the MikroTik relay,
# exactly like a phone on LTE would, then every PROBE_INTERVAL seconds checks from
# inside the tunnel: tunnel ping, handshake, DNS through the BTH resolver (names must
# come back as private addresses), and HTTP to the admin UIs. Results are written as
# Prometheus text to /www/metrics, served by busybox httpd on METRICS_PORT.
#
# Only ROUTES go into wg0. Everything else (the relay itself, Prometheus scrapes from
# Docker's 172.x) uses the container's normal default route.
set -u

: "${BTH_PRIVATE_KEY:?set in the env-file}"
: "${BTH_SERVER_PUBLIC_KEY:?}" "${BTH_ENDPOINT:?host:port}" "${BTH_ADDRESS:?a.b.c.d/32}"
PROBE_INTERVAL=${PROBE_INTERVAL:-120}
METRICS_PORT=${METRICS_PORT:-9841}
ROUTES=${ROUTES:-192.168.216.0/24,10.0.0.0/16}
TUNNEL_IP=${TUNNEL_IP:-192.168.216.1}
DNS_SERVER=${DNS_SERVER:-192.168.216.1}
DNS_NAMES=${DNS_NAMES:-grafana.int.lcserver.co.uk tower.int.lcserver.co.uk fw.int.lcserver.co.uk}
HTTP_TARGETS=${HTTP_TARGETS:-fw.int.lcserver.co.uk:440 tower.int.lcserver.co.uk:443 grafana.int.lcserver.co.uk:443 10.0.0.6:443 10.0.0.52:443 10.0.10.1:440 10.0.50.1:440}
HOST_LABEL=${HOST_LABEL:-crs326}

log() { echo "$(date -u +%FT%TZ) $*"; }

setup() {
  ip link del wg0 2>/dev/null
  ip link add wg0 type wireguard || { log "cannot create wg0 (NET_ADMIN? wireguard module?)"; return 1; }
  umask 077; printf '%s\n' "$BTH_PRIVATE_KEY" > /tmp/k
  wg set wg0 private-key /tmp/k peer "$BTH_SERVER_PUBLIC_KEY" endpoint "$BTH_ENDPOINT" \
    allowed-ips "$ROUTES" persistent-keepalive 25
  rm -f /tmp/k
  ip addr add "$BTH_ADDRESS" dev wg0
  ip link set wg0 up
  for r in $(echo "$ROUTES" | tr , ' '); do ip route replace "$r" dev wg0; done
  log "wg0 up as $BTH_ADDRESS via $BTH_ENDPOINT"
}

# Re-resolve the relay name: wg resolves an endpoint hostname only when it is set.
reresolve() { wg set wg0 peer "$BTH_SERVER_PUBLIC_KEY" endpoint "$BTH_ENDPOINT"; }

run_once() {
  start=$(date +%s); out=/www/metrics.tmp; all=1
  {
    echo "# HELP bth_probe_check_success 1 if this check passed through the BTH tunnel."
    echo "# TYPE bth_probe_check_success gauge"
  } > "$out"
  res() { # check target ok
    echo "bth_probe_check_success{host=\"$HOST_LABEL\",check=\"$1\",target=\"$2\"} $3" >> "$out"
    [ "$3" = 1 ] || { all=0; log "FAIL $1 $2"; }
  }
  if ping -c 3 -W 3 "$TUNNEL_IP" >/dev/null 2>&1; then res ping "$TUNNEL_IP" 1; else res ping "$TUNNEL_IP" 0; fi
  hs=$(wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}'); hs=${hs:-0}
  now=$(date +%s)
  if [ "$hs" -gt 0 ]; then age=$((now - hs)); else age=-1; fi
  # WireGuard re-handshakes every 2 min while traffic flows; older than 5 min = dead.
  if [ "$age" -ge 0 ] && [ "$age" -lt 300 ]; then res handshake relay 1; else res handshake relay 0; reresolve; fi
  for n in $DNS_NAMES; do
    a=$(dig +short +time=3 +tries=2 @"$DNS_SERVER" "$n" 2>/dev/null | tail -1)
    case "$a" in 10.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|192.168.*) res dns "$n" 1 ;; *) res dns "$n" 0 ;; esac
  done
  for t in $HTTP_TARGETS; do
    h=${t%:*}; p=${t#*:}; set --
    case "$h" in *[a-z]*)
      ip=$(dig +short +time=3 @"$DNS_SERVER" "$h" 2>/dev/null | tail -1)
      [ -n "$ip" ] && set -- --resolve "$h:$p:$ip" ;;
    esac
    c=$(curl -sk -o /dev/null -m 8 -w '%{http_code}' "$@" "https://$h:$p/" 2>/dev/null)
    case "$c" in [1-5][0-9][0-9]) res http "$t" 1 ;; *) res http "$t" 0 ;; esac
  done
  end=$(date +%s)
  cat >> "$out" <<EOF
# HELP bth_probe_up 1 if every check passed on the last run.
# TYPE bth_probe_up gauge
bth_probe_up{host="$HOST_LABEL"} $all
# HELP bth_probe_handshake_age_seconds Seconds since the last WireGuard handshake (-1 = never).
# TYPE bth_probe_handshake_age_seconds gauge
bth_probe_handshake_age_seconds{host="$HOST_LABEL"} $age
# HELP bth_probe_last_run_timestamp_seconds When the last run finished.
# TYPE bth_probe_last_run_timestamp_seconds gauge
bth_probe_last_run_timestamp_seconds{host="$HOST_LABEL"} $end
# HELP bth_probe_run_duration_seconds How long the last run took.
# TYPE bth_probe_run_duration_seconds gauge
bth_probe_run_duration_seconds{host="$HOST_LABEL"} $((end - start))
EOF
  mv "$out" /www/metrics
  [ "$all" = 1 ] && log "all checks passed (handshake ${age}s ago)"
}

mkdir -p /www
httpd -p "$METRICS_PORT" -h /www
until setup; do sleep 30; done
sleep 5
while :; do
  ip link show wg0 >/dev/null 2>&1 || setup
  run_once
  sleep "$PROBE_INTERVAL"
done
