---
name: check-tcc
description: Print che-ical-mcp's current TCC permission state, binary path, and ready-to-paste reset / re-prompt commands. Use when user says "check TCC", "permission status", "tccutil"。
allowed-tools:
  - Bash
---

# Check TCC Permission State

Run the v1.9.0+ binary's `--print-tcc-path` diagnostic, then present the output in a structured format.

## Execution

1. **Locate the binary**:

   ```bash
   BINARY=$(find ~/Library/Application\ Support/Claude -name CheICalMCP 2>/dev/null | head -1)
   ```

   If empty → tell user `.mcpb` is not installed in Claude Desktop and point to https://github.com/PsychQuant/che-ical-mcp/releases/latest

2. **Run the diagnostic**:

   ```bash
   "$BINARY" --print-tcc-path
   ```

3. **Present the output** with a quick interpretation:

   | Status | Meaning | Next step |
   |---|---|---|
   | `fullAccess (granted)` | ✅ OK | Tools should work |
   | `notDetermined` | Never asked | Run `"$BINARY" --setup` from Terminal |
   | `denied` | Explicitly denied | `tccutil reset` + re-grant via Step 3 |
   | `writeOnly` | Partial access | Upgrade in System Settings manually |
   | `restricted` | System policy | Check Screen Time / MDM |

4. **Remind about the two TCC layers (#168)**: the status above is **context-dependent** — it reflects the attribution of the context this command ran in (for a Claude Code session's Bash tool, that's the Claude Code side), not an absolute property of the binary. Besides the `CheICalMCP` entry, System Settings → Privacy & Security → Calendar / Reminders may need a **host-layer entry** toggled ON:

   | Host | Host-layer entry |
   |---|---|
   | Claude Code | A version-number entry like `2.1.202` (= the Claude Code native binary; rotates on every update, #170) |
   | Terminal / VS Code | The app's own name |
   | Claude Desktop | None needed (disclaimer isolation — the `.mcpb` `CheICalMCP` entry is self-contained) |

5. **If user wants the full troubleshooting walkthrough**, suggest `troubleshoot-tcc` skill (covers both layers + the complete authorization checklist) or paste the `mcpb/README.md` link.

## Why this command exists

v1.9.0 introduced `--print-tcc-path` to close the documentation gap from #108 Phase 1 — `.mcpb` users couldn't easily find the extracted binary path to run `tccutil reset` or `--setup`. This slash command is the natural-language entry point: user says "check my calendar permissions" → command runs the flag → output is self-explanatory.

Pair with `troubleshoot-tcc` skill when the output indicates a fix is needed.
