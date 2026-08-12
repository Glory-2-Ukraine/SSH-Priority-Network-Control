# SSH Priority Network Control

Ensures SSH traffic has absolute highest priority over all other network traffic on Linux. When a server is under heavy load, SSH stays responsive so you always maintain remote access — exactly when you need it most.

Tested on:
- Ubuntu 24, kernel 6.8.0-111-generic, interface ens3 (QEMU/KVM VM), 8-core server
- Raspberry Pi OS (Bookworm/Trixie), kernel 6.8+, interfaces wlan1 + tailscale0 + tun0

---

## What This Does

Uses Linux `tc` (Traffic Control) to create three priority bands on each network interface:

- **Band 1:1** — Highest priority → SSH traffic goes here
- **Band 1:2** — Normal priority → most traffic lands here by default
- **Band 1:3** — Lowest priority

The kernel empties band 1:1 completely before touching 1:2 or 1:3. SSH stays flowing even under heavy load.

IPv4 is handled with `tc u32` filters matching TCP port 22 directly.
IPv6 is handled with `ip6tables` packet marking + a `tc fw` filter (required on kernel 6.8+).

**Important:** If you use Tailscale, Pi Connect, or any VPN, rules must be applied to those interfaces too — not just your physical uplink. SSH traffic flows through the VPN interface before hitting the physical one, so rules on only `wlan1` or `eth0` won't protect Tailscale SSH sessions.

---

## Requirements

- Linux with `iproute2` installed (`tc` command)
- Root / sudo access
- `ip6tables` for IPv6 support
- systemd for persistence across reboots

Find your interfaces:
```bash
ip -br link show
```

---

## Quick Apply (Takes Effect Immediately)

### Single interface (e.g. ens3 on a VM):
```bash
IFACE="ens3"

sudo tc qdisc del dev $IFACE root 2>/dev/null || true
sudo ip6tables -t mangle -D OUTPUT -p tcp --dport 22 -j MARK --set-mark 1 2>/dev/null || true
sudo ip6tables -t mangle -D OUTPUT -p tcp --sport 22 -j MARK --set-mark 1 2>/dev/null || true

sudo tc qdisc replace dev $IFACE root handle 1: prio
sudo tc filter add dev $IFACE protocol ip parent 1:0 prio 1 u32 match ip protocol 6 0xff match tcp dst 22 0xffff flowid 1:1
sudo tc filter add dev $IFACE protocol ip parent 1:0 prio 1 u32 match ip protocol 6 0xff match tcp src 22 0xffff flowid 1:1
sudo ip6tables -t mangle -A OUTPUT -p tcp --dport 22 -j MARK --set-mark 1
sudo ip6tables -t mangle -A OUTPUT -p tcp --sport 22 -j MARK --set-mark 1
sudo tc filter add dev $IFACE parent 1:0 prio 2 handle 1 fw flowid 1:1
```

### Multiple interfaces (e.g. Raspberry Pi with Tailscale and VPN):
```bash
# Clean up ip6tables marks first
sudo ip6tables -t mangle -D OUTPUT -p tcp --dport 22 -j MARK --set-mark 1 2>/dev/null || true
sudo ip6tables -t mangle -D OUTPUT -p tcp --sport 22 -j MARK --set-mark 1 2>/dev/null || true

# Apply to each interface
for IFACE in wlan1 tailscale0 tun0; do
  sudo tc qdisc del dev $IFACE root 2>/dev/null || true
  sudo tc qdisc replace dev $IFACE root handle 1: prio
  sudo tc filter add dev $IFACE protocol ip parent 1:0 prio 1 u32 match ip protocol 6 0xff match tcp dst 22 0xffff flowid 1:1
  sudo tc filter add dev $IFACE protocol ip parent 1:0 prio 1 u32 match ip protocol 6 0xff match tcp src 22 0xffff flowid 1:1
  sudo tc filter add dev $IFACE parent 1:0 prio 2 handle 1 fw flowid 1:1
  echo "Done: $IFACE"
done

# IPv6 marks apply globally across all interfaces
sudo ip6tables -t mangle -A OUTPUT -p tcp --dport 22 -j MARK --set-mark 1
sudo ip6tables -t mangle -A OUTPUT -p tcp --sport 22 -j MARK --set-mark 1
```

Or use the included script:
```bash
sudo bash apply-ssh-qos.sh wlan1 tailscale0 tun0
```

---

## Persistent Across Reboots (systemd Service)

tc rules vanish on reboot. This service reapplies everything automatically at boot.

### For Raspberry Pi with Tailscale and VPN (wlan1 + tailscale0 + tun0):
```bash
sudo tee /etc/systemd/system/ssh-qos.service > /dev/null <<'EOF'
[Unit]
Description=SSH QoS Priority
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '\
  for IFACE in wlan1 tailscale0 tun0; do \
    tc qdisc del dev $IFACE root 2>/dev/null || true; \
    tc qdisc replace dev $IFACE root handle 1: prio && \
    tc filter add dev $IFACE protocol ip parent 1:0 prio 1 u32 match ip protocol 6 0xff match tcp dst 22 0xffff flowid 1:1 && \
    tc filter add dev $IFACE protocol ip parent 1:0 prio 1 u32 match ip protocol 6 0xff match tcp src 22 0xffff flowid 1:1 && \
    tc filter add dev $IFACE parent 1:0 prio 2 handle 1 fw flowid 1:1; \
  done; \
  ip6tables -t mangle -D OUTPUT -p tcp --dport 22 -j MARK --set-mark 1 2>/dev/null || true; \
  ip6tables -t mangle -D OUTPUT -p tcp --sport 22 -j MARK --set-mark 1 2>/dev/null || true; \
  ip6tables -t mangle -A OUTPUT -p tcp --dport 22 -j MARK --set-mark 1 && \
  ip6tables -t mangle -A OUTPUT -p tcp --sport 22 -j MARK --set-mark 1'
ExecStop=/bin/bash -c '\
  for IFACE in wlan1 tailscale0 tun0; do \
    tc qdisc del dev $IFACE root 2>/dev/null || true; \
  done; \
  ip6tables -t mangle -D OUTPUT -p tcp --dport 22 -j MARK --set-mark 1 2>/dev/null || true; \
  ip6tables -t mangle -D OUTPUT -p tcp --sport 22 -j MARK --set-mark 1 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now ssh-qos.service
```

### For a single-interface VM (ens3 only):
Replace the `for IFACE in wlan1 tailscale0 tun0` loop with a single interface in both ExecStart and ExecStop.

---

## Verify It Is Working

```bash
# Check each interface
for IFACE in wlan1 tailscale0 tun0; do
  echo "--- $IFACE ---"
  sudo tc qdisc show dev $IFACE
  sudo tc filter show dev $IFACE
done

# Check ip6tables marks
sudo ip6tables -t mangle -L OUTPUT -v --line-numbers

# Check service status
sudo systemctl status ssh-qos.service --no-pager
```

Expected filter output per interface:
```
filter parent 1: protocol ip pref 1 u32 chain 0 fh 800::800 ... *flowid 1:1
  match 00060000/00ff0000 at 8
  match 00000016/0000ffff at nexthdr+0
filter parent 1: protocol ip pref 1 u32 chain 0 fh 800::801 ... *flowid 1:1
  match 00060000/00ff0000 at 8
  match 00160000/ffff0000 at nexthdr+0
filter parent 1: protocol all pref 2 fw chain 0 handle 0x1 classid 1:1
```

Expected service status: `active (exited) status=0/SUCCESS`

---

## Remove Everything

```bash
sudo systemctl disable --now ssh-qos.service
for IFACE in wlan1 tailscale0 tun0; do
  sudo tc qdisc del dev $IFACE root 2>/dev/null || true
done
sudo ip6tables -t mangle -D OUTPUT -p tcp --dport 22 -j MARK --set-mark 1
sudo ip6tables -t mangle -D OUTPUT -p tcp --sport 22 -j MARK --set-mark 1
```

---

## Troubleshooting

### SSH still slow over Tailscale or Pi Connect
Rules must be on `tailscale0` and `tun0` as well as your physical interface. SSH over Tailscale goes through `tailscale0` first — rules only on `wlan1` won't help. Apply to all three interfaces using the multi-interface block above.

### "Filter already exists" error
Rules from a previous run are still in place. Clean up first:
```bash
for IFACE in wlan1 tailscale0 tun0; do
  sudo tc qdisc del dev $IFACE root 2>/dev/null || true
done
sudo ip6tables -t mangle -D OUTPUT -p tcp --dport 22 -j MARK --set-mark 1 2>/dev/null || true
sudo ip6tables -t mangle -D OUTPUT -p tcp --sport 22 -j MARK --set-mark 1 2>/dev/null || true
```

### "Filter with specified priority/protocol not found" after last command
Misleading error from older iproute2. Appears after the final filter because tc tries a confirmation lookup and finds nothing to compare against. Run the verify commands — if filters show up, it worked.

### IPv6 filters fail with kernel error on kernel 6.8+
tc u32 IPv6 filters are not supported on kernel 6.8+. Use the ip6tables mark approach in this repo. Do not attempt `protocol ipv6` u32 filters on this kernel.

### Service fails on start
```bash
sudo journalctl -xeu ssh-qos.service | tail -30
```
Most likely leftover rules from a manual run. The service cleans up first with `|| true` so this should be automatic.

### Wrong interface name
```bash
ip -br link show
```
Replace interface names throughout to match your system.

### Service starts too early (rules apply before interface is up)
Use `network-online.target` not `network.target`. On VMs and Raspberry Pi, `network.target` does not guarantee interfaces are configured yet.

---

## Technical Notes

### Why rules must go on VPN interfaces too
Tailscale and tun-based VPNs encapsulate traffic in their own interface before it reaches the physical NIC. By the time packets hit `wlan1`, they are already encapsulated and the original TCP port 22 header is hidden inside the tunnel. Applying rules on `tailscale0` and `tun0` catches SSH before encapsulation.

### Why the default priomap is correct
The prio qdisc default priomap is `1 2 2 2 1 2 0 0 1 1 1 1 1 1 1 1`. Most normal traffic maps to bands 1:2 and 1:3. SSH filters push port 22 into 1:1. Setting all priomap values to 0 puts everything in 1:1, giving SSH no actual advantage.

### Why `match tcp dst` not `match ip dport`
The tc u32 `tcp` selector uses `dst`/`src` for ports, not `dport`/`sport`. Those belong to the `ip` selector. Wrong keyword causes tc to silently reject the filter.

### Why `network-online.target`
On VMs and Raspberry Pi, `network.target` does not guarantee specific interfaces are configured. `network-online.target` waits for at least one interface to be fully online first.

### Why the service cleans up before applying
`tc filter add` fails if a filter already exists. Cleaning first with `2>/dev/null || true` makes the service fully idempotent — safe to restart any number of times.

---

## Files in This Repo

| File | Description |
|------|-------------|
| `README.md` | This file — full setup guide (English) |
| `README.ua.md` | Full setup guide (Ukrainian) |
| `apply-ssh-qos.sh` | Script to apply rules immediately, accepts interface list as arguments |
| `ssh-qos.service` | Systemd service unit file (wlan1 + tailscale0 + tun0) |
| `ssh-qos-configuration.docx` | Full technical writeup (English) |
| `ssh-qos-configuration.ua.docx` | Full technical writeup (Ukrainian) |

---

## Tested On

- Ubuntu 24, kernel 6.8.0-111-generic, interface ens3 (QEMU/KVM), iproute2 6.1.0, 8-core
- Raspberry Pi OS, kernel 6.8+, interfaces wlan1 + tailscale0 + tun0 (Tailscale + Pi Connect)
