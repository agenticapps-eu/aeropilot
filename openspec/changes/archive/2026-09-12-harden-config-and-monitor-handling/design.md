## Context
Existing shell setup and single-file Swift companion; changes coordinated across two repos.

## Goals / Non-Goals
Reliable hardware routing, preserved sessions and float preferences. No native Space deletion, remote-server change or automatic app restart.

## Decisions
Use a standard-library Python controller with desktop/laptop rule files, runtime profile state under ~/.local/state/aerospace, a bounded process lock, and delayed new-window callback. Hardware determines profile; no independent toggle state. Temporary floating state records window id plus pid, restores only matching windows and respects pinned floats. Same-profile monitor events only reload config. Explicit Discover flattens only workspace 2, orders all tiles using swap and verifies neighboring IDs before joining; restore focus in finally. Swift reads published active rules; config writes resolve symlinks. Build uses xcrun swiftc, staging, strict signing verification and previous-bundle recovery.

## Risks / Trade-offs
New-window callback runs after static callbacks, so a short transient move is possible. Unrecognized display names default to desktop. Native Spaces remain user managed. State and CLI failures must not falsely mark transitions successful. Concurrent events serialize; no callbacks after partial state publication. Physical cable testing requires user hardware interaction.

## Migration Plan
Test in isolated directories; deploy compatible companion first, then setup scripts and canonical symlink after backing up live files. Preserve original source and live bundles until verified.

## Open Questions
None blocking; physical monitor tests remain explicit verification limits.

## Resolved interface and review decisions (2026-09-12)

`~/.local/state/aerospace/profile.json` is the sole publication point, atomically
replaced UTF-8 JSON: version=1, profile=desktop|laptop|null, floats and positions
maps. The companion reads version/profile and selects env/layout.conf or
layout.laptop.conf; absent/unknown state falls back to desktop reporting.
The controller refuses unknown/corrupt state without routing. Map entries carry
window ID, PID, process start and bundle ID, and are pruned against live windows.
Unknown JSON entry shapes are errors, never a reason to restore a window.

The shared entry point is ~/.config/aerospace/env/monitorwechsel.sh. AeroPilot
falls back to reload only if it is absent; setup scripts are installed before
starting the new companion. Monitor notifications use trailing-edge debounce
and startup also reconciles. Each serialized controller run queries current
hardware after acquiring its lock; calls time out after 10 seconds, lock waits
fail visibly after 20 seconds. Errors go to layout.log and AeroPilot's message.
There is no unconditional automatic retry loop. Explicit relayout retries.
Same-profile monitor callbacks reload only. Reload does not explicitly run
on-window-detected; only the real window callback routes new windows.

Laptop requires a positively recognized built-in panel only. A nonempty external
name (including unknown models) is desktop; duplicate external names do not affect
this binary decision. Empty/failed detection aborts. Monitor positioning remains
AeroSpace's configured monitor-name fallback, not a new UUID matching scheme.
Discover is explicitly DESKTOP workspace 2; laptop Zen uses workspace 4 and
Discover refuses laptop execution. Discover failure leaves a valid flat/partially
ordered WS2, never joins unverified neighbors, and restores focus. It cannot
reconstruct an arbitrary previous tree. Only explicit Discover rebuilds WS2.

TOML is never round-tripped through Python. Swift retains supplied editor text
and atomically writes the resolved symlink target; validation failure restores
previous bytes. No callback restarts user applications. Deploying AeroPilot
itself intentionally restarts the companion only, after compile/signature checks.
The build EXIT trap restores the previous bundle if activation/start fails.
`touch ~/.local/state/aerospace/disabled` disables controller mutation; remove it
and run monitorwechsel.sh to resume. Logs rotate at 1 MB.

Review: external Kimi K3 findings were addressed or explicitly narrowed above.
Gemini could not review (quota 429), Claude timed out. These are not approvals;
only one external vendor produced a review. Hardware cable testing remains a
manual acceptance check; fake hardware/CLI and real Swift harnesses cover logic.
