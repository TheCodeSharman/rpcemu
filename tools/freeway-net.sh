#!/usr/bin/env bash
#
# freeway-net.sh — host-side networking to put an RPCEmu guest onto the physical
# LAN so Acorn Access / Freeway (ShareFS over AUN) works between RPCEmu and a
# real RISC PC, over WiFi.
#
# This is the manual/ad-hoc companion to the NixOS module nix/rpcemu-freeway.nix
# (which does the same thing declaratively at boot). Use it for quick bring-up
# on any Linux host.
#
# Why this is needed: a WiFi AP won't forward Ethernet frames for a MAC it never
# associated (the emulated 02:00:a4:.. guest MAC), so a true L2 bridge is
# impossible. Instead we route at L3 and use the kernel's own proxy-ARP so the
# guest's IP appears, to the rest of the LAN, to live "behind" the host's uplink.
# Plain routing drops broadcasts, and Freeway *discovers* peers by broadcasting
# to UDP 32770 — so we also run udp-broadcast-relay-redux to copy those between
# the uplink and the tap, forging the original sender so replies come straight
# back.
#
# RPCEmu attaches to the persistent tap created here (owned by $OWNER) and needs
# NO privilege itself (feature/iptunnel-persistent-tap: rpc.cfg
# network_type=iptunnelling, tunnelinterface=<tap>). ALL privileged work is
# confined to this one script.
#
# The relay binary is resolved from $RELAY_BIN, else PATH. Get it with e.g.
#   nix run  github:TheCodeSharman/rpcemu#udp-broadcast-relay-redux -- ...
#   nix shell github:TheCodeSharman/rpcemu#udp-broadcast-relay-redux
#
# Usage:
#   sudo ./freeway-net.sh up      # tap + routing + proxy-ARP + firewall
#   sudo ./freeway-net.sh relay   # run the broadcast relay in the foreground
#   sudo ./freeway-net.sh status  # show current state
#   sudo ./freeway-net.sh down    # tear it all back down
#
set -euo pipefail

# ---- configuration (override via environment) ----------------------------
WIFI="${WIFI:-wlp0s20f3}"          # host uplink (real LAN)
TAP="${TAP:-rpctap0}"              # persistent tap RPCEmu attaches to
TAP_IP="${TAP_IP:-192.168.88.11}"  # host end of the tap link (must be free)
GUEST_IP="${GUEST_IP:-192.168.88.12}" # RISC OS guest IP (must be free)
PREFIX="${PREFIX:-24}"             # LAN prefix length (the guest's netmask)
BCAST="${BCAST:-192.168.88.255}"   # LAN broadcast address
PORT="${PORT:-32770}"              # Freeway discovery UDP port to RELAY (observed
                                   # from the real RISC PC: <ip>.32770 broadcasts).
                                   # The INPUT firewall accepts ALL udp broadcast,
                                   # so there is no port list to maintain.
RELAY_ID="${RELAY_ID:-1}"          # udp-broadcast-relay instance id (1-99)
OWNER="${OWNER:-${SUDO_USER:-$USER}}" # user that owns the tap / runs RPCEmu
RELAY_BIN="${RELAY_BIN:-$(command -v udp-broadcast-relay-redux || true)}"

msg() { printf '  %s\n' "$*"; }
hdr() { printf '\n== %s ==\n' "$*"; }

require_root() {
	if [ "$(id -u)" -ne 0 ]; then
		echo "error: must run as root (use: sudo $0 $*)" >&2
		exit 1
	fi
}

require_relay() {
	if [ -z "$RELAY_BIN" ] || [ ! -x "$RELAY_BIN" ]; then
		echo "error: udp-broadcast-relay-redux not found." >&2
		echo "       set RELAY_BIN=/path/to/it, or put it on PATH, e.g.:" >&2
		echo "       nix shell github:TheCodeSharman/rpcemu#udp-broadcast-relay-redux" >&2
		exit 1
	fi
}

cmd_up() {
	require_root up

	hdr "IP forwarding"
	sysctl -qw net.ipv4.ip_forward=1
	msg "net.ipv4.ip_forward=1"

	hdr "Persistent tap ($TAP, owned by $OWNER)"
	if ! ip link show "$TAP" >/dev/null 2>&1; then
		ip tuntap add dev "$TAP" mode tap user "$OWNER"
		msg "created $TAP (mode tap, user $OWNER)"
	else
		msg "$TAP already exists"
	fi
	ip link set "$TAP" up
	# /32 + explicit broadcast: gives the relay a valid SIOCGIFBRDADDR without
	# adding a LAN-subnet route via the tap that would steal the uplink's route.
	if ! ip -4 addr show dev "$TAP" | grep -q "inet $TAP_IP/"; then
		ip addr add "$TAP_IP/32" broadcast "$BCAST" dev "$TAP"
		msg "assigned $TAP_IP/32 brd $BCAST to $TAP"
	fi
	ip route replace "$GUEST_IP/32" dev "$TAP"
	msg "route: $GUEST_IP/32 dev $TAP"

	hdr "Proxy-ARP + reverse-path"
	for i in all "$WIFI" "$TAP"; do
		sysctl -qw "net.ipv4.conf.$i.proxy_arp=1"
		sysctl -qw "net.ipv4.conf.$i.rp_filter=2"
	done
	msg "proxy_arp=1, rp_filter=2 on $WIFI + $TAP"

	hdr "Firewall"
	for pair in "$TAP:$WIFI" "$WIFI:$TAP"; do
		in="${pair%%:*}"; out="${pair##*:}"
		if ! iptables -C FORWARD -i "$in" -o "$out" -j ACCEPT 2>/dev/null; then
			iptables -I FORWARD -i "$in" -o "$out" -j ACCEPT
			msg "forward $in -> $out"
		fi
	done
	# Broadcasts terminate on the relay's own socket on THIS host, so they must
	# pass the INPUT firewall. Accept ALL udp broadcast (any port); unicast-to-
	# host stays filtered.
	if ! iptables -C INPUT -p udp -m addrtype --dst-type BROADCAST -j ACCEPT 2>/dev/null; then
		iptables -I INPUT -p udp -m addrtype --dst-type BROADCAST -j ACCEPT
		msg "INPUT: accept all udp broadcast"
	fi

	hdr "Done"
	msg "Start RPCEmu (tunnelinterface=$TAP), set the guest to $GUEST_IP/$PREFIX,"
	msg "then in another terminal: sudo $0 relay"
}

cmd_relay() {
	require_root relay
	require_relay
	echo "Relaying UDP $PORT between $WIFI and $TAP (Ctrl-C to stop)..."
	exec "$RELAY_BIN" -d --id "$RELAY_ID" --port "$PORT" --dev "$WIFI" --dev "$TAP"
}

cmd_down() {
	require_root down
	hdr "Firewall"
	for pair in "$TAP:$WIFI" "$WIFI:$TAP"; do
		in="${pair%%:*}"; out="${pair##*:}"
		while iptables -C FORWARD -i "$in" -o "$out" -j ACCEPT 2>/dev/null; do
			iptables -D FORWARD -i "$in" -o "$out" -j ACCEPT
		done
	done
	while iptables -C INPUT -p udp -m addrtype --dst-type BROADCAST -j ACCEPT 2>/dev/null; do
		iptables -D INPUT -p udp -m addrtype --dst-type BROADCAST -j ACCEPT
	done
	msg "removed forward + broadcast rules"

	hdr "Routing / proxy-ARP / tap"
	ip route del "$GUEST_IP/32" dev "$TAP" 2>/dev/null || true
	for i in "$WIFI" "$TAP"; do
		sysctl -qw "net.ipv4.conf.$i.proxy_arp=0" 2>/dev/null || true
	done
	if ip link show "$TAP" >/dev/null 2>&1; then
		ip tuntap del dev "$TAP" mode tap && msg "deleted $TAP"
	fi
	msg "(net.ipv4.ip_forward left unchanged)"
}

cmd_status() {
	hdr "tap $TAP"; ip -br addr show "$TAP" 2>/dev/null || msg "absent"
	hdr "route to guest"; ip route show "$GUEST_IP/32" 2>/dev/null || msg "none"
	hdr "sysctl"
	for i in "$WIFI" "$TAP"; do
		printf '  %s: proxy_arp=%s rp_filter=%s\n' "$i" \
			"$(cat "/proc/sys/net/ipv4/conf/$i/proxy_arp" 2>/dev/null || echo -)" \
			"$(cat "/proc/sys/net/ipv4/conf/$i/rp_filter" 2>/dev/null || echo -)"
	done
	printf '  ip_forward=%s\n' "$(cat /proc/sys/net/ipv4/ip_forward)"
	hdr "firewall"
	iptables -S FORWARD 2>/dev/null | grep -E "$TAP|$WIFI" || msg "no forward rules"
	iptables -S INPUT 2>/dev/null | grep -E 'addrtype --dst-type BROADCAST' || msg "no broadcast accept"
	hdr "relay"; pgrep -a udp-broadcast 2>/dev/null || msg "not running"
}

case "${1:-}" in
	up)     cmd_up ;;
	relay)  cmd_relay ;;
	down)   cmd_down ;;
	status) cmd_status ;;
	*) echo "usage: sudo $0 {up|relay|status|down}" >&2; exit 2 ;;
esac
