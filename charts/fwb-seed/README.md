# fwb-seed

A separate, minimal NetherNet Bedrock server whose world is generated from the
same seed as FWB (`3021625704163385757`). A fresh world: none of FWB's builds,
only its terrain. Same difficulty (hard), survival, no cheats, version 1.26.60.6.

| | |
|---|---|
| LAN join | `192.168.1.163:31301` |
| Public join | `mc.jdwlabs.com:19135` (needs VM nft + gateway rules, below) |
| Server / signaling / gameplay | 31300 / 31301 / 31310-31329 |
| Public TCP / UDP | 19135 -> 31301 / 19200-19219 -> 31310-31329 |
| Node | `talos-lx0-6a4` |
| Limits | 750m cpu, 1Gi (needs the 26Gi tenant quota) |

Public route (R3, by hand): add TCP 19135 and UDP 19200-19219 to the VM's
`/etc/minecraft-udp-nat.nft`, and a gateway Custom Service for UDP 19200-19219
(TCP 19135 is inside the existing 19132-19141 forward). See
`docs/minecraft-nethernet-public-route.md`.

No backups, by decision. This chart installs no packs.
