FROM alpine:3.20
RUN apk add --no-cache wireguard-tools-wg iproute2 bind-tools curl busybox-extras
COPY probe.sh /probe.sh
RUN chmod 755 /probe.sh
EXPOSE 9841
# Healthy = the probe loop is running (metrics fresher than 3 intervals), NOT that BTH
# passes: a BTH outage is for the alert, not a reason for Docker to restart us.
HEALTHCHECK --interval=60s --timeout=5s --start-period=180s \
  CMD [ -f /www/metrics ] && [ $(( $(date +%s) - $(stat -c %Y /www/metrics) )) -lt $(( ${PROBE_INTERVAL:-120} * 3 )) ] || exit 1
CMD ["/probe.sh"]
