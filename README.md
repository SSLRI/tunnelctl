# TunnelCTL

A self-hosted SSH tunnelling server for Linux VPS boxes, with a clean terminal
console for managing accounts, transports, limits and traffic.

[راهنمای فارسی](README.fa.md)

One installer sets up three ways to reach the same SSH daemon:

| Transport | Default port | Use case |
|---|---|---|
| SSH direct | 22 (plus an optional fallback port) | fastest path, normal networks |
| TLS via stunnel | 443 | traffic looks like ordinary HTTPS |
| WebSocket | 80 | HTTP upgrade handshake for payload based clients |
| WebSocket over TLS | 8443 | HTTP upgrade wrapped inside TLS |

---

## Features

**Accounts**
- Create accounts with an expiry date, a simultaneous connection limit and a traffic quota
- Lock, unlock, extend, change password, delete
- Accounts are shell-less by policy: they can forward ports and nothing else
- A ready to copy connection card for every account, including a client payload

**Enforcement**
- A watchdog runs every minute and locks expired accounts, locks accounts over quota
  and drops sessions above the connection limit
- Traffic is measured per account with nftables counters and accumulated in the database

**Security**
- Hardened `sshd` policy: modern ciphers and key exchange only, three auth attempts,
  short login grace, no agent forwarding, no X11, no user rc files
- Tunnel accounts are confined by a `Match Group` block and a forced command
- Firewall applied automatically through ufw, firewalld or nftables, default deny inbound
- Optional fail2ban jail covering every port the tool exposes
- Kernel tuning with BBR, fq, TCP fast open, syn cookies and raised descriptor limits

**Operations**
- Live session view with peer address and uptime
- Traffic report with per account and total usage
- Backup and restore, including password hashes, so a server can be rebuilt in minutes
- Everything reachable from an interactive console or from scriptable subcommands

---

## Requirements

- Ubuntu 20.04+, Debian 11+, or an RHEL family release with `dnf`
- Root access
- A server with a stable public IP address
- Ports 22, 80 and 443 free, or your own choice of ports

---

## Install

```bash
git clone https://github.com/sslri/tunnelctl.git
cd tunnelctl
sudo bash install.sh
```

The installer asks for your public IP or domain, the ports you want, and the
default limits for new accounts. It validates the SSH configuration before
reloading it and rolls back automatically if the test fails.

Keep your current SSH session open until you have confirmed that you can log in
again on the configured port.

---

## Usage

Open the console:

```bash
sudo tunnelctl
```

```
  TunnelCTL 1.0.0  SSH Tunnel Suite
  ----------------------------------------------------------------
  Server                 203.0.113.10
  Transports             SSH 22  TLS 443  WS 80
  Services               sshd active  tls active  ws active
  Accounts               12 total, 4 online, 1 expired, 0 locked

  1) Accounts             5) Firewall and hardening
  2) Live connections     6) Backup and restore
  3) Traffic report       7) Settings
  4) Transports           8) About
  0) Exit
```

Or drive it from scripts:

```bash
tunnelctl add alice 30 2 50      # 30 days, 2 connections, 50 GB
tunnelctl show alice
tunnelctl renew alice 30
tunnelctl lock alice
tunnelctl online
tunnelctl traffic
tunnelctl backup
tunnelctl status
tunnelctl check                  # which ports are listening
tunnelctl repair                 # rebuild transports and firewall rules
```

Run `tunnelctl help` for the full list.

---

## Connecting

### Command line

```bash
ssh -N -D 1080 -p 22 alice@your-server
```

Then point your browser or system proxy at `SOCKS5 127.0.0.1:1080`.

### Mobile and desktop tunnel clients

| Setting | Value |
|---|---|
| Host | your server IP or domain |
| Port | 22 for direct, 443 for TLS, 80 for WebSocket |
| Username / Password | from the account card |
| Mode | Direct, SSL/TLS, or WebSocket depending on the port |
| SNI / Host | your domain, or any hostname when using a self signed certificate |

Payload for HTTP upgrade clients:

```
GET / HTTP/1.1[crlf]Host: your-server[crlf]Upgrade: websocket[crlf][crlf]
```

The TLS transport uses a self signed certificate by default, so clients must be
allowed to accept it. If you point a real domain at the server you can replace
`/etc/tunnelctl/certs/stunnel.pem` with a certificate from a public CA, then
restart the transport with `systemctl restart tunnelctl-tls`.

---

## Layout

```
/usr/local/bin/tunnelctl          entry point
/usr/local/lib/tunnelctl/         libraries and helpers
/etc/tunnelctl/tunnelctl.conf     configuration
/etc/tunnelctl/users.db           account database
/etc/tunnelctl/certs/             TLS material
/etc/ssh/sshd_config.d/10-tunnelctl.conf
/etc/stunnel/tunnelctl.conf
/var/backups/tunnelctl/           backup archives
/var/log/tunnelctl.log            audit log
```

Systemd units: `tunnelctl-tls.service`, `tunnelctl-ws.service`,
`tunnelctl-watchdog.timer`.

---

## Notes on traffic accounting

Counters are attached to each account's user id in a dedicated nftables table
with an accept policy, so they never interfere with your firewall. They measure
the traffic generated by that account's tunnel sessions. Values are folded into
the database once a minute and the counters are reset, which keeps totals
accurate across reboots and service restarts.

If `nft` is unavailable the tool still works, only the traffic report stays at
zero.

---

## Uninstall

```bash
sudo bash uninstall.sh
```

It stops and removes the services, restores the original `sshd_config`, and asks
before touching your accounts and data.

---

## Troubleshooting

| Symptom | Check |
|---|---|
| Menu says "Unknown option" | you are on 1.0.0, update to 1.1.0 |
| A transport shows "not installed" | `sudo tunnelctl repair` |
| Transport will not start | `journalctl -u tunnelctl-ws -u tunnelctl-tls -n 50` |
| Port 80 or 443 already taken | stop the web server, or pick other ports in Settings |
| Client connects then drops | connection limit reached, see the account limits |
| Account cannot log in | expired or over quota, check `tunnelctl list` |
| Locked out after a port change | use the provider console, then `tunnelctl` to fix the firewall |

---

## License

MIT. See [LICENSE](LICENSE).

## Contact

- Email: asksslri@gmail.com
- Telegram: [@sslri](https://t.me/sslri)
- Instagram: [@sslri](https://instagram.com/sslri)

Use this tool only on servers you own or are authorised to administer, and in
line with the laws that apply to you.
