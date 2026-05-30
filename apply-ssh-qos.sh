#!/bin/bash
# apply-ssh-qos.sh
# Applies SSH traffic priority rules on ens3 immediately.
# Safe to run multiple times — cleans up existing rules first.
# Tested on Ubuntu 24, kernel 6.8.0-111-generic, iproute2 6.1.0

set -e

IFACE="${1:-ens3}"

echo "[ssh-qos] Applying SSH QoS rules on interface: $IFACE"

# Clean up any existing rules
echo "[ssh-qos] Clearing existing rules..."
tc qdisc del dev "$IFACE" root 2>/dev/null || true
ip6tables -t mangle -D OUTPUT -p tcp --dport 22 -j MARK --set-mark 1 2>/dev/null || true
ip6tables -t mangle -D OUTPUT -p tcp --sport 22 -j MARK --set-mark 1 2>/dev/null || true

# Create priority qdisc with default priomap
echo "[ssh-qos] Creating priority qdisc..."
tc qdisc replace dev "$IFACE" root handle 1: prio

# IPv4: outbound SSH to highest priority band
echo "[ssh-qos] Adding IPv4 outbound SSH filter..."
tc filter add dev "$IFACE" protocol ip parent 1:0 prio 1 u32 \
  match ip protocol 6 0xff \
  match tcp dst 22 0xffff \
  flowid 1:1

# IPv4: inbound SSH responses to highest priority band
echo "[ssh-qos] Adding IPv4 inbound SSH filter..."
tc filter add dev "$IFACE" protocol ip parent 1:0 prio 1 u32 \
  match ip protocol 6 0xff \
  match tcp src 22 0xffff \
  flowid 1:1

# IPv6: mark SSH packets via ip6tables (required on kernel 6.8+)
echo "[ssh-qos] Adding IPv6 ip6tables marks..."
ip6tables -t mangle -A OUTPUT -p tcp --dport 22 -j MARK --set-mark 1
ip6tables -t mangle -A OUTPUT -p tcp --sport 22 -j MARK --set-mark 1

# IPv6: route marked packets to highest priority band
echo "[ssh-qos] Adding IPv6 fw filter..."
tc filter add dev "$IFACE" parent 1:0 prio 2 handle 1 fw flowid 1:1

echo "[ssh-qos] Done. Verifying..."
echo ""
tc qdisc show dev "$IFACE"
echo ""
tc filter show dev "$IFACE"
echo ""
echo "[ssh-qos] SSH traffic is now highest priority on $IFACE"
