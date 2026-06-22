## ADDED Requirements

### Requirement: Interactive --setup presents TCC dialogs from a foreground app context

When `--setup` runs in an interactive session, the binary SHALL request Calendar and Reminders full access from inside a foreground `NSApplication` (regular activation policy with a running main run loop) so that macOS EventKit can present its system permission dialogs. The binary SHALL NOT issue the interactive requests from a bare CLI async context, because on macOS 14+ the first such request returns denied without ever presenting a dialog.

#### Scenario: Calendar and Reminders dialogs present and are granted

- **WHEN** a user runs `<binary> --setup` from Terminal in an interactive session and clicks Allow on both dialogs
- **THEN** the system presents the Calendar TCC dialog, then the Reminders TCC dialog
- **AND** the binary prints `Calendar access: ✓ granted` and `Reminders access: ✓ granted`
- **AND** the binary exits with status 0

#### Scenario: A permission is denied during interactive setup

- **WHEN** a user runs `<binary> --setup` interactively and denies the Calendar dialog
- **THEN** the binary prints `Calendar access: ✗ denied`
- **AND** the binary prints manual-grant guidance for System Settings → Privacy & Security
- **AND** the binary exits with a non-zero status

#### Scenario: Framework error during a request is sanitized

- **WHEN** an EventKit request throws an error during interactive setup
- **THEN** the binary prints the entity's access line with the error text passed through control-character sanitization
- **AND** the run is treated as failed (non-zero exit)

### Requirement: Non-interactive --setup reports status without blocking on a dialog

When `--setup` runs in a session detected as non-interactive, the binary SHALL report each entity's authorization status headlessly and exit, and SHALL NOT enter the foreground `NSApplication` run loop or attempt a request that would block waiting for a dialog that cannot appear. Non-interactive detection for `--setup` SHALL treat `CI=1` alone as still interactive (a person in Terminal may have `CI` exported), matching the established `--setup` detection policy.

#### Scenario: Non-interactive session skips the would-block request

- **WHEN** `--setup` runs in a non-interactive session and Calendar access is not yet determined
- **THEN** the binary prints a warning that dialogs cannot appear here
- **AND** the binary prints a skipped status for the entity rather than blocking on a dialog
- **AND** the binary exits without entering the run loop

#### Scenario: Already-granted entity reports without prompting

- **WHEN** `--setup` runs (interactive or not) and an entity already has full access
- **THEN** the binary prints `<entity> access: ✓ already granted` for that entity and issues no request for it

### Requirement: Permission-denied responses surface the resolvable binary path and --setup command

When a tool call fails because Calendar or Reminders access is insufficient, and when the startup banner detects that access is not granted, the output SHALL include the resolved absolute path of the currently running binary and a copy-pasteable `"<path>" --setup` command, so a user of the Claude Desktop `.mcpb` install can authorize the correct binary identity. The path SHALL be produced by the existing binary-path resolver and SHALL pass through control-character sanitization before display.

#### Scenario: Calendar tool call denied surfaces the setup command

- **WHEN** a Calendar tool call fails due to insufficient authorization
- **THEN** the error response includes the resolved absolute binary path
- **AND** the response includes a `"<resolved-path>" --setup` command line

#### Scenario: Startup banner surfaces the setup command on missing access

- **WHEN** the startup banner runs and detects Calendar access is not granted
- **THEN** the banner output includes the resolved absolute binary path and a `"<resolved-path>" --setup` command line
