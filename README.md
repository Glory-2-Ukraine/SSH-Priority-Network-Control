# SSH Priority Network Control

Ensures SSH traffic has absolute highest priority over all other network traffic on Linux. When a server is under heavy load, SSH stays responsive so you always maintain remote access — exactly when you need it most.

Tested on Ubuntu 24 with kernel 6.8.0-111-generic, interface ens3 (QEMU/KVM VM).

---

## What This Does

Uses Linux `tc` (Traffic Control) to create three priority bands on your network interface:

- **Band 1:1** — Highest priority → SSH traffic goes here
- **Band 1:2** — Normal priority → most traffic lands here by default
- **Band 1:3** — Lowest priority

The kernel empties band 1:1 completely before touching 1:2 or 1:3. SSH stays flowing even under heavy network load.

IPv4 is handled with `tc u32` filters matching TCP port 22 directly.
IPv6 is handled with `ip6tables` packet marking + a `tc fw` filter (required on kernel 6.8+).

---

## Requirements

- Linux with `iproute2` installed (`tc` command)
- Root / sudo access
- `ip6tables` for IPv6 support
- systemd for persistence across reboots

Find your interface name:
```bash
ip -br link show
```
Replace `ens3` throughout with your actual interface if different.

---

## Quick Apply (Takes Effect Immediately)

```bash
# Remove any existing rules cleanly
sudo tc qdisc del dev ens3 root 2>/dev/null || true
sudo ip6tables -t mangle -D OUTPUT -p tcp --dport 22 -j MARK --set-mark 1 2>/dev/null || true
sudo ip6tables -t mangle -D OUTPUT -p tcp --sport 22 -j MARK --set-mark 1 2>/dev/null || true

# Create priority qdisc with default priomap
sudo tc qdisc replace dev ens3 root handle 1: prio

# IPv4: outbound SSH to highest priority band
sudo tc filter add dev ens3 protocol ip parent 1:0 prio 1 u32 \
  match ip protocol 6 0xff \
  match tcp dst 22 0xffff \
  flowid 1:1

# IPv4: inbound SSH responses to highest priority band
sudo tc filter add dev ens3 protocol ip parent 1:0 prio 1 u32 \
  match ip protocol 6 0xff \
  match tcp src 22 0xffff \
  flowid 1:1

# IPv6: mark SSH packets via ip6tables
sudo ip6tables -t mangle -A OUTPUT -p tcp --dport 22 -j MARK --set-mark 1
sudo ip6tables -t mangle -A OUTPUT -p tcp --sport 22 -j MARK --set-mark 1

# IPv6: route marked packets to highest priority band
sudo tc filter add dev ens3 parent 1:0 prio 2 handle 1 fw flowid 1:1
```

---

## Persistent Across Reboots (systemd Service)

tc rules vanish on reboot. This service reapplies everything automatically at boot.

```bash
sudo tee /etc/systemd/system/ssh-qos.service > /dev/null <<EOF
[Unit]
Description=SSH QoS Priority
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '\
  tc qdisc del dev ens3 root 2>/dev/null || true; \
  ip6tables -t mangle -D OUTPUT -p tcp --dport 22 -j MARK --set-mark 1 2>/dev/null || true; \
  ip6tables -t mangle -D OUTPUT -p tcp --sport 22 -j MARK --set-mark 1 2>/dev/null || true; \
  tc qdisc replace dev ens3 root handle 1: prio && \
  tc filter add dev ens3 protocol ip parent 1:0 prio 1 u32 match ip protocol 6 0xff match tcp dst 22 0xffff flowid 1:1 && \
  tc filter add dev ens3 protocol ip parent 1:0 prio 1 u32 match ip protocol 6 0xff match tcp src 22 0xffff flowid 1:1 && \
  ip6tables -t mangle -A OUTPUT -p tcp --dport 22 -j MARK --set-mark 1 && \
  ip6tables -t mangle -A OUTPUT -p tcp --sport 22 -j MARK --set-mark 1 && \
  tc filter add dev ens3 parent 1:0 prio 2 handle 1 fw flowid 1:1'
ExecStop=/bin/bash -c '\
  tc qdisc del dev ens3 root; \
  ip6tables -t mangle -D OUTPUT -p tcp --dport 22 -j MARK --set-mark 1; \
  ip6tables -t mangle -D OUTPUT -p tcp --sport 22 -j MARK --set-mark 1'

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now ssh-qos.service
```

---

## Verify It Is Working

```bash
# Check qdisc and filters
sudo tc qdisc show dev ens3
sudo tc filter show dev ens3

# Check ip6tables marks
sudo ip6tables -t mangle -L OUTPUT -v --line-numbers

# Check service status
sudo systemctl status ssh-qos.service
```

Expected output from `tc filter show dev ens3`:
```
filter parent 1: protocol ip pref 1 u32 chain 0
filter parent 1: protocol ip pref 1 u32 chain 0 fh 800::800 ... *flowid 1:1
  match 00060000/00ff0000 at 8
  match 00000016/0000ffff at nexthdr+0
filter parent 1: protocol ip pref 1 u32 chain 0 fh 800::801 ... *flowid 1:1
  match 00060000/00ff0000 at 8
  match 00160000/ffff0000 at nexthdr+0
filter parent 1: protocol all pref 2 fw chain 0 handle 0x1 classid 1:1
```

Expected from `systemctl status`: `active (exited) status=0/SUCCESS`

---

## Remove Everything

```bash
sudo systemctl disable --now ssh-qos.service
sudo tc qdisc del dev ens3 root
sudo ip6tables -t mangle -D OUTPUT -p tcp --dport 22 -j MARK --set-mark 1
sudo ip6tables -t mangle -D OUTPUT -p tcp --sport 22 -j MARK --set-mark 1
```

---

## Troubleshooting

### "Filter already exists" error
Rules from a previous run are still in place. Clean up first:
```bash
sudo tc qdisc del dev ens3 root 2>/dev/null || true
sudo ip6tables -t mangle -D OUTPUT -p tcp --dport 22 -j MARK --set-mark 1 2>/dev/null || true
sudo ip6tables -t mangle -D OUTPUT -p tcp --sport 22 -j MARK --set-mark 1 2>/dev/null || true
```
Then re-run the apply block.

### "Filter with specified priority/protocol not found" after last command
This is a misleading error from older iproute2 versions. It appears after the final filter is added because tc tries a confirmation lookup and finds nothing to compare against. Run the verify commands — if filters show up, it worked.

### IPv6 filters fail with kernel error on kernel 6.8+
tc u32 IPv6 filters are not supported on kernel 6.8.0-111-generic. Use the ip6tables mark approach provided in this repo. Do not attempt `protocol ipv6` u32 filters on this kernel.

### Service fails on start
Check the journal:
```bash
sudo journalctl -xeu ssh-qos.service | tail -30
```
Most likely cause is leftover rules from a manual apply. The service's ExecStart cleans up first with `|| true` so this should be handled automatically.

### Wrong interface name
Find yours with:
```bash
ip -br link show
```
Replace every instance of `ens3` in the commands and service file with your interface name.

### Service starts too early on reboot (rules apply before interface is up)
Make sure the service uses `network-online.target` not `network.target`. On VMs (QEMU/KVM, MAC prefix 52:54:00) `network.target` does not guarantee the interface is configured yet.

---

## Technical Notes

### Why the default priomap is correct
The prio qdisc default priomap is `1 2 2 2 1 2 0 0 1 1 1 1 1 1 1 1`. Most normal traffic maps to bands 1:2 and 1:3. SSH filters push port 22 into 1:1. Setting all priomap values to 0 is a common mistake that puts everything in 1:1, giving SSH no actual advantage.

### Why `match tcp dst` not `match ip dport`
The tc u32 `tcp` selector uses `dst`/`src` for ports. The keywords `dport`/`sport` belong to the `ip` selector. Using the wrong keyword causes tc to silently reject the filter with a confusing error.

### Why `network-online.target`
On QEMU/KVM virtual machines, `network.target` does not guarantee specific interfaces are configured. `network-online.target` waits for at least one interface to be fully online before the service runs.

### Why the service cleans up before applying
`tc filter add` fails if a matching filter already exists. Cleaning first with `2>/dev/null || true` makes the service fully idempotent — safe to start, stop, and restart any number of times.

---

## Files in This Repo

| File | Description |
|------|-------------|
| `README.md` | This file — full setup guide |
| `apply-ssh-qos.sh` | One-shot script to apply all rules immediately |
| `ssh-qos.service` | Systemd service unit file |
| `ssh-qos-configuration.docx` | Full technical writeup document |

---

## Tested On

- Ubuntu 24, kernel 6.8.0-111-generic
- Interface: ens3 (QEMU/KVM virtual NIC, MAC 52:54:00:*)
- iproute2 6.1.0
- 8-core server
