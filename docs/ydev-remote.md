# ydev remote backend

## Setup
`just init` → fill the remote section of `.env` (HCLOUD_TOKEN [project 2],
BWS_ACCESS_TOKEN, BWS_SERVER_URL, HCLOUD_SSH_KEY_NAME, optional YDEV_*).
`just doctor` (needs hcloud + bws for remote).

## Loop
`just remote up` → `just remote build [machine]` → `just remote qemu` |
`just remote download [machine]` → `just remote down`. `just remote status`
shows uptime (≈cost); `just remote clean` kills orphaned ydev boxes.

## Auto-teardown (you never have to `down`)
1. Idle-watchdog: box self-deletes after YDEV_IDLE_MINUTES idle.
2. Max-lifetime: self-delete after YDEV_MAX_HOURS regardless.
3. Nightly backstop — add to your M920q crontab:
   `0 3 * * * cd /path/to/linux-image && just remote clean >/dev/null 2>&1`

CI build servers (label-less / `oe5xrx-yocto-builder-*`) are never touched:
clean is strictly `label_selector=managed-by==ydev`.
