## ADDED Requirements

### Requirement: Interactive --setup presents a window showing live Calendar and Reminders status

When `--setup` runs in an interactive session, the foreground app SHALL present a window that displays the current authorization status of Calendar and Reminders. The window SHALL re-check status on a recurring interval so it reflects a newly granted permission without manual refresh. The non-interactive path SHALL NOT present a window and SHALL continue to report status headlessly and exit.

#### Scenario: Window shows current status on open

- **WHEN** a user runs `<binary> --setup` interactively
- **THEN** a window opens listing Calendar and Reminders, each with its current authorization status (granted / denied / not yet determined)

#### Scenario: Window reflects a grant without manual refresh

- **WHEN** the user grants access (via the window's grant button or System Settings) while the window is open
- **THEN** the corresponding entity's status updates to granted within the recurring re-check interval
- **AND** when both Calendar and Reminders are granted the window indicates the setup is ready

#### Scenario: Non-interactive setup presents no window

- **WHEN** `--setup` runs in a session detected as non-interactive
- **THEN** no window is presented and the binary reports each entity's status and exits

### Requirement: The window grants access directly and surfaces the authorization target binary

The window SHALL provide a per-entity control that requests full access directly (triggering the system permission dialog when status is not yet determined), reusing the established setup access decision. The window SHALL display the resolved absolute path of the binary being authorized and SHALL provide actions to copy that path and to open the relevant System Settings privacy pane (the fallback path after a denial, where the request API no longer re-prompts).

#### Scenario: Grant button triggers the system dialog

- **WHEN** the user activates the grant control for an entity whose status is not yet determined
- **THEN** the binary issues a full-access request for that entity, presenting the system permission dialog

#### Scenario: Window surfaces the resolved binary path

- **WHEN** the window is open
- **THEN** it displays the resolved absolute path of the running binary
- **AND** provides a control to copy that path and a control to open the System Settings privacy pane
