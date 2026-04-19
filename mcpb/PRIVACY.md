# Privacy Policy for che-ical-mcp

**Last Updated: January 14, 2026**

## Overview

che-ical-mcp is a local MCP (Model Context Protocol) server that provides Claude with access to your macOS Calendar and Reminders apps. This extension operates entirely on your local machine and does not transmit any data to external servers.

## Data Access

This extension accesses the following data on your Mac:

### Calendar Data
- **Event information**: Title, start/end times, location, notes, URL, attendees
- **Calendar metadata**: Calendar names, colors, and source information (iCloud, Google, Exchange, etc.)
- **Recurring event patterns**: Recurrence rules and exceptions

### Reminders Data
- **Reminder information**: Title, due dates, priority, notes, completion status
- **Reminder list metadata**: List names and source information

## Data Processing

### Local Processing Only
- **All data processing occurs locally** on your Mac
- **No data is transmitted** to Anthropic, the developer, or any third-party servers
- **No data is stored** by this extension beyond the current session

### How Data Flows
1. Claude sends a request to the local MCP server (e.g., "list today's events")
2. The MCP server queries Apple's EventKit framework on your Mac
3. Results are returned to Claude through the local MCP protocol
4. Data never leaves your computer

## Permissions

On first use, macOS will request permission for this extension to access:

| Permission | Purpose |
|------------|---------|
| **Calendar** | Required to read, create, update, and delete calendar events |
| **Reminders** | Required to read, create, update, and delete reminders |

You can revoke these permissions at any time in **System Settings → Privacy & Security**.

## Data Retention

- This extension **does not store any calendar or reminder data**
- All operations are performed in real-time through Apple's EventKit API
- No logs, caches, or copies of your data are created by this extension

## Third-Party Services

This extension interacts with calendars from various sources that you have configured in macOS Calendar:

- **iCloud Calendar**: Subject to [Apple's Privacy Policy](https://www.apple.com/privacy/)
- **Google Calendar**: Subject to [Google's Privacy Policy](https://policies.google.com/privacy)
- **Microsoft Exchange/Outlook**: Subject to [Microsoft's Privacy Statement](https://privacy.microsoft.com/)
- **Other CalDAV services**: Subject to their respective privacy policies

This extension does not have direct access to these services' servers; it only accesses calendar data that has already been synced to your Mac through macOS.

## Security

- The extension runs with the same permissions as the Claude Desktop application
- Communication between Claude and the MCP server uses stdio (standard input/output) on your local machine
- No network connections are made by this extension

## Open Source

This extension is open source. You can review the complete source code at:
https://github.com/PsychQuant/che-ical-mcp

## Platform Limitation

This extension is **macOS only** because it uses Apple's EventKit framework, which is only available on Apple platforms.

## Contact

For privacy concerns or questions, please:
- Open an issue on [GitHub](https://github.com/PsychQuant/che-ical-mcp/issues)
- Contact the developer: [@kiki830621](https://github.com/kiki830621)

## Changes to This Policy

Any changes to this privacy policy will be posted to the GitHub repository and reflected in the "Last Updated" date above.
