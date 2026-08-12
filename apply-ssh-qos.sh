#!/bin/bash
# apply-ssh-qos.sh
# Applies SSH traffic priority rules on all active interfaces.
# Covers the primary uplink plus VPN interfaces (Tailscale, tun0).
# Safe to run multiple times — cleans up existing rules first.
# Tested on Raspberry Pi OS, Ubuntu 24, kernel 6.8+, iproute2 6.1.0

set -e

# Default interfaces — edit this list to match your setup
INTERFACES="${@:-wlan1 tailscale0 tun0}"

echo "[ssh-qos] Applying SSH QoS rules"

# Clean up ip6tables marks first
echo "[ssh-qos] Clearing existing ip6tables marks..."
ip6tables -t mangle -D OUTPUT -p tcp --dport 22 -j MARK --set-mark 1 2>/dev/null || true
ip6tables -t mangle -D OUTPUT -p tcp --sport 22 -j MARK --set-mark 1 2>/dev/null || true

# Apply rules to each interface
for IFACE in $INTERFACES; do
  if ip link show "$IFACE" > /dev/null 2>&1; then
    echo "[ssh-qos] Configuring $IFACE..."
    tc qdisc del dev "$IFACE" root 2>/dev/null || true
    tc qdisc replace dev "$IFACE" root handle 1: prio
    tc filter add dev "$IFACE" protocol ip parent 1:0 prio 1 u32 \
      match ip protocol 6 0xff \
      match tcp dst 22 0xffff \
      flowid 1:1
    tc filter add dev "$IFACE" protocol ip parent 1:0 prio 1 u32 \
      match ip protocol 6 0xff \
      match tcp src 22 0xffff \
      flowid 1:1
    tc filter add dev "$IFACE" parent 1:0 prio 2 handle 1 fw flowid 1:1
    echo "[ssh-qos] Done: $IFACE"
  else
    echo "[ssh-qos] Skipping $IFACE (not found)"
  fi
done

# Apply ip6tables marks (covers IPv6 SSH across all interfaces)
echo "[ssh-qos] Adding IPv6 ip6tables marks..."
ip6tables -t mangle -A OUTPUT -p tcp --dport 22 -j MARK --set-mark 1
ip6tables -t mangle -A OUTPUT -p tcp --sport 22 -j MARK --set-mark 1

echo ""
echo "[ssh-qos] Verification:"
for IFACE in $INTERFACES; do
  if ip link show "$IFACE" > /dev/null 2>&1; then
    echo "--- $IFACE qdisc ---"
    tc qdisc show dev "$IFACE"
    echo "--- $IFACE filters ---"
    tc filter show dev "$IFACE"
  fi
done
echo ""
echo "[ssh-qos] SSH traffic is now highest priority on: $INTERFACES"
