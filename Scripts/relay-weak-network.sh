#!/usr/bin/env bash
# The relay harness over a bad link: the relay in a Linux container with
# `tc netem` on its interface (latency, jitter, loss, reordering, a rate
# cap), the harness on this Mac reaching it through the published port.
#
#   Scripts/relay-weak-network.sh <relay-harness> [profile...]
#
# Profiles: lossy (cellular on a good day), awful (one bar, moving), and
# flapping (the link drops entirely for a few seconds, twice). Needs docker
# and the image `ighostvt-relay:dev` (`docker build -t ighostvt-relay:dev Relay`).
set -euo pipefail

harness="${1:?usage: relay-weak-network.sh <relay-harness> [profile...]}"
shift
profiles=("${@:-lossy awful flapping}")
# shellcheck disable=SC2206
profiles=(${profiles[*]})

name="ighostvt-relay-netem"
volume="ighostvt-relay-netem"
port=46499
work="$(mktemp -d)"
trap 'docker rm -f "$name" >/dev/null 2>&1 || true; docker volume rm "$volume" >/dev/null 2>&1 || true; rm -rf "$work"' EXIT

# A sidecar in the relay's network namespace applies the rules, since the
# relay image is scratch and has no tc. Built once, with tc in it.
printf 'FROM alpine:3\nRUN apk add --no-cache iproute2\n' | docker build -q -t ighostvt-netem:local - >/dev/null

netem() {
    docker run --rm --network "container:$name" --cap-add NET_ADMIN ighostvt-netem:local \
        tc qdisc replace dev eth0 root netem "$@"
}

profile_rules() {
    case "$1" in
    lossy) echo "delay 80ms 25ms distribution normal loss 2% rate 20mbit" ;;
    awful) echo "delay 250ms 80ms distribution normal loss 7% 25% reorder 5% 50% rate 2mbit" ;;
    flapping) echo "delay 60ms 20ms loss 1% rate 10mbit" ;;
    *) echo "unknown profile $1" >&2; exit 64 ;;
    esac
}

profile_scale() {
    case "$1" in
    # Loss caps one TCP stream near MSS / RTT / sqrt(loss): about 150 KB/s
    # at 2 % and 80 ms, 20 KB/s at 7 % and 250 ms. The volumes follow.
    lossy) echo 0.01 ;;
    awful) echo 0.001 ;;
    flapping) echo 0.005 ;;
    esac
}

start_relay() {
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker run -d --name "$name" -p "127.0.0.1:$port:46405" \
        -e RELAY_PUBLIC_HOST=127.0.0.1 -e RELAY_PUBLIC_PORT="$port" -e RELAY_RATE_PER_IP=0 \
        -v "$volume:/data" ighostvt-relay:dev >/dev/null
}

status=0
for profile in "${profiles[@]}"; do
    rules="$(profile_rules "$profile")"
    echo "== $profile: $rules"
    docker volume rm "$volume" >/dev/null 2>&1 || true
    start_relay
    for _ in $(seq 50); do
        docker exec "$name" ighostvt-relay config >"$work/relay.vtrpsc" 2>/dev/null && break
        sleep 0.2
    done
    # shellcheck disable=SC2086
    netem $rules
    # A restart makes a new network namespace: the rules go on again.
    restart="docker restart -t 0 $name >/dev/null && docker run --rm --network container:$name --cap-add NET_ADMIN ighostvt-netem:local tc qdisc replace dev eth0 root netem $rules"
    flapper=""
    if [[ "$profile" == flapping ]]; then
        # Twice during the run, the link goes dead for five seconds.
        (
            sleep 20
            for _ in 1 2; do
                netem loss 100% || true
                sleep 5
                # shellcheck disable=SC2086
                netem $rules || true
                sleep 40
            done
        ) &
        flapper=$!
    fi
    if ! RELAY_CONFIG="$work/relay.vtrpsc" RELAY_RESTART_COMMAND="$restart" \
        RELAY_SLOW_FACTOR=4 RELAY_STRESS_SCALE="$(profile_scale "$profile")" \
        "$harness" --external --stress; then
        status=1
    fi
    [[ -z "$flapper" ]] || wait "$flapper" || true
    echo "relay log tail:"
    docker logs --tail 15 "$name" 2>&1 | sed 's/^/    /'
done
exit "$status"
