# Local Yocto builds against the shared cache (M920q)

The CI shares its sstate/downloads via a Hetzner Storage Box. Point your local
build at the same box so you pull warm sstate instead of compiling everything
(essential on the 8 GB M920q).

## One-time: mount the box
```bash
# key-only; Hetzner Storage Box SSH/SFTP is on port 23.
mkdir -p /mnt/yocto-shared
sudo sshfs -p 23 \
  -o IdentityFile=$HOME/.ssh/storagebox,allow_other,reconnect,ServerAliveInterval=15 \
  <box-user>@<box-host>:/ /mnt/yocto-shared
```
`<box-user>`/`<box-host>` are the Bitwarden secrets `yocto-cache-storage-box-user`/`-host`;
`~/.ssh/storagebox` is the box private key from Bitwarden.

## Build
`kas build qemux86-64.yml` — `oe5xrx.yml` auto-detects the mount and sets
`SSTATE_MIRRORS`/`DL_DIR` accordingly (`SSTATE_DIR` stays local under `build/`).
Your local build compiles only what changed; the rest comes from the mirror.

## Note
Local builds do NOT push sstate back (only CI does, to keep the mirror a clean
CI-produced artifact). If you want your local sstate to seed the box, rsync it
up manually: `rsync -a --ignore-existing build/sstate-cache/ /mnt/yocto-shared/sstate/`.
