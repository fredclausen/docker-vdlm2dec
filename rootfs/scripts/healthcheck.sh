#!/usr/bin/with-contenv bash
# shellcheck shell=bash

# Import healthchecks-framework
# shellcheck disable=SC1091
source /opt/healthchecks-framework/healthchecks.sh

# Default original codes
EXITCODE=0

# ===== Local Helper Functions =====

function get_pid_of_decoder {

  # $1: service_dir
  service_dir="$1"

  # Ensure variables are unset
  unset DEVICE_ID FREQS_VDLM VDLM_BIN FREQS_ACARS ACARS_BIN

  # Get DEVICE_ID
  eval "$(grep "DEVICE_ID=\"" "$service_dir"/run)"

  # Get FREQS_ACARS
  eval "$(grep "FREQ_STRING=\"" "$service_dir"/run)"

  # Get VDLM_BIN
  eval "$(grep "VDLM_BIN=\"" "$service_dir"/run)"

  # Get PS output for the relevant process
  if [[ -n "$VDLM_BIN" ]]; then
    # shellcheck disable=SC2009
    ps_output=$(ps aux | grep "$VDLM_BIN" | grep " -r $DEVICE_ID " | grep " $FREQ_STRING")
  fi

  # Find the PID of the decoder based on command line
  process_pid=$(echo "$ps_output" | tr -s " " | cut -d " " -f 2)

  # Return the process_pid
  echo "$process_pid"

}

# ===== Check vdlmdec processes =====

# For each service...
for service_dir in /etc/services.d/*; do
  service_name=$(basename "$service_dir")

  # If the service is vdlmdec-*...
  if [[ "$service_name" == vdlm2dec ]]; then

    decoder_pid=$(get_pid_of_decoder "$service_dir")
    decoder_udp_port="5555"
    decoder_server_prefix="vdlm2dec"

  # If the server isn't vdlm2dec-.
  else
    # skip it!
    continue
  fi

  # If the process doesn't exists, then fail

  echo "==== Checking $service_name ====="

  if [[ -z "$decoder_pid" ]]; then
    echo "Cannot find PID of decoder $service_name: UNHEALTHY"
    EXITCODE=1
  else
    # If the process does exist, then make sure it has made a connection to localhost on the relevant port.
    if ! check_udp4_connection_established_for_pid "127.0.0.1" "ANY" "127.0.0.1" "$decoder_udp_port" "$decoder_pid"; then
      echo "Decoder $service_name (pid $decoder_pid) not connected to ${decoder_server_prefix}_server at 127.0.0.1:$decoder_udp_port: UNHEALTHY"
      EXITCODE=1
    else
      echo "Decoder $service_name (pid $decoder_pid) is connected to ${decoder_server_prefix}_server at 127.0.0.1:$decoder_udp_port: HEALTHY"
    fi
  fi

done

# ===== Check vdlm_server, vdlm_feeder, vdlm_stats processes =====

echo "==== Checking vdlm_server ====="

# Check vdlm_server is listening for TCP on 127.0.0.1:15550
acars_pidof_acars_tcp_server=$(pgrep -f 'ncat -4 --keep-open --listen 0.0.0.0 15555')
if ! check_tcp4_socket_listening_for_pid "0.0.0.0" "15555" "${acars_pidof_acars_tcp_server}"; then
    echo "vdlm_server TCP not listening on port 15555 (pid $acars_pidof_acars_tcp_server): UNHEALTHY"
    EXITCODE=1
else
    echo "vdlm_server TCP listening on port 15555 (pid $acars_pidof_acars_tcp_server): HEALTHY"
fi

echo "==== Checking vdlm_stats ====="

# Check vdlm_stats:
acars_pidof_acars_stats=$(pgrep -fx 'socat -u TCP:127.0.0.1:15555 CREATE:/run/acars/vdlm2.past5min.json')

# Ensure TCP connection to vdlm_server at 127.0.0.1:15555
if ! check_tcp4_connection_established_for_pid "127.0.0.1" "ANY" "127.0.0.1" "15555" "${acars_pidof_acars_stats}"; then
echo "vdlm_stats (pid $acars_pidof_acars_stats) not connected to acars_server (pid $acars_pidof_acars_tcp_server) at 127.0.0.1:15555: UNHEALTHY"
EXITCODE=1
else
echo "vdlm_stats (pid $acars_pidof_acars_stats) connected to acars_server (pid $acars_pidof_acars_tcp_server) at 127.0.0.1:15555: HEALTHY"
fi

echo "==== Check for VDLM activity ====="

# Check for activity
# read .json files, ensure messages received in past hour
acars_num_msgs_past_hour=$(find /run/acars -type f -name 'vdlm2.*.json' -cmin -60 -exec cat {} \; | wc -l)
if [[ "$acars_num_msgs_past_hour" -gt 0 ]]; then
    echo "$acars_num_msgs_past_hour VDLM messages received in past hour: HEALTHY"
else
    echo "$acars_num_msgs_past_hour VDLM messages received in past hour: UNHEALTHY"
    EXITCODE=1
fi

echo "==== Check Service Death Tallies ====="

# Check service death tally
mapfile -t SERVICES < <(find /run/s6/services -maxdepth 1 -type d -not -name "*s6-*" | tail +2)
for service in "${SERVICES[@]}"; do
  SVDT=$(s6-svdt "$service" | grep -cv 'exitcode 0')
  if [[ "$SVDT" -gt 0 ]]; then
    echo "abnormal death tally for $(basename "$service") since last check is: $SVDT: UNHEALTHY"
    EXITCODE=1
  else
    echo "abnormal death tally for $(basename "$service") since last check is: $SVDT: HEALTHY"
  fi
  s6-svdt-clear "$service"
done

exit "$EXITCODE"
