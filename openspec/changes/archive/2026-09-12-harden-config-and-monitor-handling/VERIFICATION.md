# Verification — 2026-09-12

- Python routing suite: 14 passed, including hardware round trip, window callbacks,
  helper restoration, PID reuse, permanent floats, CLI failures, corrupt state,
  close-during-move and extra Discover tiles.
- Real Swift monitor harness: unchanged/burst/reconnect/repeated start/geometry passed.
- Real Swift config harness: symlink target save and rollback passed.
- Build failure harness: existing installation survives compiler failure.
- xcrun optimized arm64 build, strict codesign verification and plist validation passed.
- All setup shell scripts parse with bash -n; git diff --check passed.
- Live AeroSpace dry-run accepts the deployed configuration.
- Actual on-window-detected callback routes Zen to desktop WS2.
- Repeated same-profile monitor handler preserves all observed window assignments/layouts.
- Explicit Discover completed against real desktop windows, preserving original focus.
- Installed AeroPilot runs and reports successful desktop profile reconciliation on startup.
- Backups under ~/.local/state/aerospace/backups/optimizations-20260912-124831;
  previous companion retained as ~/Applications/AeroPilot.previous.app.

Physical unplug/replug in both directions has not been performed. Both LG and
Odyssey remained connected for live verification. Reader pairing and laptop
routing were verified with simulated windows, not by closing user applications.
Focused external code review completed; wider review timed out. Gemini quota
and Claude timeout prevented a second independent vendor review.
