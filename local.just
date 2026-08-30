# `just local <recipe>` — build/boot/flash on THIS machine.
set dotenv-load := true

# Build locally (sstate from the public R2 mirror). Args any order: [machine] [--dev].
# e.g. `just local build --dev` (qemux86-64 dev-image) or `just local build raspberrypi4-64 --dev`.
build *args:
    scripts/ydev/local-build.sh {{args}}

# Boot the built qemux86-64 image locally in QEMU (serial in this terminal).
# `just local qemu --dev` boots the dev-image instead — then attach the Fast-Dev-Loop
# from another terminal with `just dev qemu`.
qemu *args:
    scripts/run-qemu.sh {{ if args =~ '(^| )--?dev($| )' { "--dev-agent" } else { "" } }}

# Write the raspberrypi4-64 .wic to an SD/device (guarded). No device -> lists candidates.
flash device="":
    scripts/ydev/local-flash.sh {{device}}
