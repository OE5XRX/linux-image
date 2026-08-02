# ydev remote backend

## Setup
`just init` → fill the remote section of `.env` (HCLOUD_TOKEN [project 2],
BWS_ACCESS_TOKEN, BWS_SERVER_URL, HCLOUD_SSH_KEY_NAME, optional YDEV_*).
`just doctor` (reports hcloud + bws + the remote ssh key for remote use).

### SSH key
`HCLOUD_SSH_KEY_NAME` names the key Hetzner injects into the box. If the matching
private key isn't your ssh default (`~/.ssh/id_*`) or in your ssh-agent, set
`HCLOUD_SSH_KEY` to its path (e.g. `~/.ssh/yocto-builder`) — otherwise ssh falls
back to a password prompt. All remote ssh/scp/rsync then use `-i` with that key.

The box's host-key fingerprint is **ignored by default** (`StrictHostKeyChecking=no`
+ `UserKnownHostsFile=/dev/null`): Hetzner recycles IPs, so a fresh box often reuses
an IP already in your `known_hosts` and ssh would otherwise refuse. These are
disposable boxes created via the authenticated hcloud API. (The box→storage-box
mount keeps normal host-key checking.)

## Loop
`just remote up` → `just remote build [machine]` → `just remote qemu` |
`just remote download [machine]` → `just remote down`. `just remote status`
shows uptime (≈cost); `just remote clean` kills orphaned ydev boxes.

> **`just remote qemu` is slow:** cloud boxes have no `/dev/kvm`, so QEMU runs
> under TCG software emulation (boots, but minutes not seconds). For interactive
> testing prefer `just remote download` then `just local qemu` on a KVM host.

## Auto-teardown (you never have to `down`)
The teardown is armed **at server creation via cloud-init user-data** — so it runs
from the first boot even if the laptop's SSH provisioning fails. A half-provisioned
box can never linger and bill.
1. Idle-watchdog: box self-deletes after YDEV_IDLE_MINUTES idle.
2. Max-lifetime: self-delete after YDEV_MAX_HOURS regardless.
3. Nightly backstop — add to your M920q crontab:
   `0 3 * * * cd /path/to/linux-image && just remote clean >/dev/null 2>&1`

If `just remote up` fails mid-provisioning, no `.ydev-session` is written; that box
still self-deletes via cloud-init, or you can force it with `just remote clean`.

CI build servers (label-less / `oe5xrx-yocto-builder-*`) are never touched:
clean is strictly `label_selector=managed-by==ydev`.

**Security note:** to let the box delete *itself*, the delete-capable `HCLOUD_TOKEN`
is written into the cloud-init user-data (and `/etc/ydev/token`, 0600). user-data is
readable on the box via the metadata endpoint — an accepted tradeoff for a
guaranteed create-time teardown.
