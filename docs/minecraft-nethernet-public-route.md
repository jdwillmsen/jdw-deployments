# Joining a Bedrock server from outside the LAN (NetherNet)

Retail Bedrock clients (Windows, Xbox, phone) dial NetherNet only. A server on
`transport=nethernet` needs a TCP port for signaling and a UDP port per
connected client for gameplay, and the server must tell the client an address
it can reach. The old RakNet-only forward (UDP 19132-19141) carries none of it.

First hit on 2026-11-01: remote players got "Terracotta"/NetherNet errors while
the server was healthy on the LAN.

## The path

```
player ── TCP 19132 / UDP 19160-19179 ──▶ BGW320 gateway (forwards to the VM)
       ──▶ HAProxy VM 192.168.1.199, table ip minecraft (DNAT + masquerade)
       ──▶ node NodePort 31134 (TCP) / 31160-31179 (UDP) ──▶ server pod
```

| Server | Players enter | Signaling (TCP) | Gameplay (UDP) | NodePorts |
|---|---|---|---|---|
| FWB | `mc.jdwlabs.com` (port 19132) | 19132 -> 31134 | 19160-19179 | 31160-31179 |
| Crew lab | `mc.jdwlabs.com:19133` | 19133 -> 31137 | 19140-19159 | 31140-31159 |
| Proving grounds | `mc.jdwlabs.com:19134` | 19134 -> 31201 | 19180-19199 | 31210-31229 |

External `191NN` maps to NodePort `311NN` for FWB and the lab; proving grounds uses the
mapping in its row (19134 -> 31201, 19180 -> 31210 in order). The existing gateway rule
"K8 Talos Cluster - UDP" forwards TCP and UDP 19132-19141; each gameplay range
beyond it is a custom service (UDP, base host port equal to the first port so
the gateway never rewrites a port) attached to the HAProxy VM, matched by MAC
because the gateway's device names are wrong.

## The server must advertise the WAN address

`SERVER_UDP_PORTS=<address>:<external range>:<internal range>`. The address is
what clients are told to send gameplay UDP to, so it is the WAN address
(`104.53.12.62`), not the node. Consequences:

- The WAN address is **not static**. If the ISP changes it, remote joins break
  until the value is updated in each chart (`curl -s ifconfig.me`).
- LAN and in-cluster clients (bots, agent, crew units) cannot reach the WAN
  address themselves because the gateway does not loop traffic back. They still
  connect: ICE checks run both ways, so the server reaches their addresses. The
  bots rejoining after the change is the check for this.

## Failure modes seen

- **No listener after an in-place restart.** The server binds its signaling port
  once at start. TIME_WAIT sockets from the old process, kept alive by the pod's
  network namespace, make the bind fail silently, and the server runs for hours
  with nothing listening (2026-10-31 and 2026-11-01, about 3.4 h). `Accepting
  clients on [::]:<port>` is missing from the startup log. Fixed by the restart
  job re-checking the port and by `listener-watchdog.yaml`, which restarts any
  server whose container is older than 6 minutes with no listener.
- **Remote players still fail with the VM counters at zero.** `sudo nft list
  table ip minecraft` on the VM: a TCP counter that rises with the UDP counters
  at 0 means the gateway is not forwarding the gameplay range.

## Adding a server

1. Pick the next `191NN` signaling port and a 20-port gameplay range.
2. Add the DNAT and masquerade rules to `/etc/minecraft-udp-nat.nft` on the VM
   (validate with `nft -c -f`, keep a dated backup, apply with `nft -f`).
3. Add a gateway custom service (UDP, base port = first port) to the VM.
4. Set the server's `SERVER_UDP_PORTS` to `<WAN address>:<external>:<internal>`.
