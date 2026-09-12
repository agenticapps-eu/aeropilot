# safe-config-and-monitor Specification

## Purpose
TBD - created by archiving change harden-config-and-monitor-handling. Update Purpose after archive.
## Requirements
### Requirement: Symlink safe configuration transaction
Config saves SHALL resolve the destination symlink before atomic writes, preserve the live symlink and comments, and roll back invalid writes.

#### Scenario: Saving float pins through a symlink
- **WHEN** Saving float pins through a symlink
- **THEN** The canonical repository file changes, the symlink survives, and invalid content restores the previous file.

### Requirement: Debounced profile-aware monitor changes
Screen events SHALL be debounced and invoke the shared monitor handler when installed, falling back to reload when absent. Initial startup SHALL reconcile current hardware once.

#### Scenario: Multiple LG events occur in a burst
- **WHEN** Multiple LG events occur in a burst
- **THEN** One settled callback runs, using shared hardware routing, without resetting same-profile window trees.

### Requirement: Staged builds
Build SHALL compile and verify a staged signed bundle before stopping or replacing the installed app; failures SHALL preserve the installed bundle.

#### Scenario: Swift compilation or signing fails
- **WHEN** Swift compilation or signing fails
- **THEN** The running installed app and executable remain unchanged.

### Requirement: Active profile matches UI
Misplaced-window diagnostics SHALL use active laptop or desktop rules including wildcard fallback.

#### Scenario: Laptop is active
- **WHEN** Laptop is active
- **THEN** UI does not suggest desktop destinations for laptop windows.

