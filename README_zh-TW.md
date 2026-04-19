# che-ical-mcp

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![macOS](https://img.shields.io/badge/macOS-13.0%2B-blue)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange.svg)](https://swift.org/)
[![MCP](https://img.shields.io/badge/MCP-Compatible-green.svg)](https://modelcontextprotocol.io/)

**macOS 行事曆與提醒事項 MCP 伺服器** - 原生 EventKit 整合，完整的行事曆和任務管理。

[English](README.md) | [繁體中文](README_zh-TW.md)

---

## 為什麼選擇 che-ical-mcp？

| 功能 | 其他行事曆 MCP | che-ical-mcp |
|------|----------------|--------------|
| 行事曆事件 | 有 | 有 |
| **提醒事項/任務** | 無 | **有** |
| **提醒事項 #標籤** | 無 | **有**（MCP 層級） |
| **多關鍵字搜尋** | 無 | **有** |
| **重複事件偵測** | 無 | **有** |
| **衝突檢測** | 無 | **有** |
| **批次操作** | 無 | **有** |
| **本地時區** | 無 | **有** |
| **來源消歧義** | 無 | **有** |
| 建立行事曆 | 部分 | 有 |
| 刪除行事曆 | 部分 | 有 |
| 事件提醒 | 部分 | 有 |
| 地點與網址 | 部分 | 有 |
| 開發語言 | Python | **Swift (原生)** |

---

## 快速開始

### Claude Desktop

#### 方式 A：MCPB 一鍵安裝（推薦）

從 [Releases](https://github.com/kiki830621/che-ical-mcp/releases) 下載最新的 `.mcpb` 檔案，雙擊即可安裝。

#### 方式 B：手動設定

編輯 `~/Library/Application Support/Claude/claude_desktop_config.json`：

```json
{
  "mcpServers": {
    "che-ical-mcp": {
      "command": "/usr/local/bin/che-ical-mcp"
    }
  }
}
```

### Claude Code (CLI)

#### 方式 A：安裝為 Plugin（推薦）

Plugin 包含快捷指令（`/today`、`/week`、`/quick-event`、`/remind`）、skills，以及**建立/修改事件時自動驗證星期的 PreToolUse hook** — 防止日期與星期不符的錯誤。

兩個步驟 — 先註冊 marketplace，再安裝 plugin：

```bash
# 1. 註冊 marketplace（一次性）
claude plugin marketplace add PsychQuant/psychquant-claude-plugins

# 2. 安裝 plugin
claude plugin install che-ical-mcp@psychquant-claude-plugins
```

> **已經在 Claude Code 裡？** 等價的 slash-command `/plugin marketplace add PsychQuant/psychquant-claude-plugins` 和 `/plugin install che-ical-mcp@psychquant-claude-plugins` 效果相同。

> **備註：** Plugin 內建自動下載功能。如果 `~/bin/CheICalMCP` 不存在，首次使用時會自動從 GitHub Releases 下載。

#### 方式 B：僅安裝 MCP Server

如果只需要 MCP 功能，不需要 plugin 附加功能：

```bash
# 建立 ~/bin（如果不存在）
mkdir -p ~/bin

# 下載最新版本
curl -L https://github.com/kiki830621/che-ical-mcp/releases/latest/download/CheICalMCP -o ~/bin/CheICalMCP
chmod +x ~/bin/CheICalMCP

# 加入 Claude Code
# --scope user    : 跨所有專案可用（存在 ~/.claude.json）
# --transport stdio: 本地 binary 執行，透過 stdin/stdout
# --              : 分隔 claude 選項和實際執行的命令
claude mcp add --scope user --transport stdio che-ical-mcp -- ~/bin/CheICalMCP
```

> **💡 提示：** 請將 binary 安裝到本機目錄如 `~/bin/`。避免放在雲端同步資料夾（Dropbox、iCloud、OneDrive），否則檔案同步可能造成 MCP 連線逾時。

### 從原始碼編譯（可選）

```bash
git clone https://github.com/kiki830621/che-ical-mcp.git
cd che-ical-mcp
make release && make install
```

首次使用時，macOS 會詢問**行事曆**和**提醒事項**存取權限 - 請點選「允許」。

---

## 全部 28 個工具

<details>
<summary><b>行事曆 (4)</b></summary>

| 工具 | 說明 |
|------|------|
| `list_calendars` | 列出所有行事曆和提醒事項清單（包含 source_type） |
| `create_calendar` | 建立新行事曆 |
| `delete_calendar` | 刪除行事曆 |
| `update_calendar` | 重新命名行事曆或更改顏色（v0.9.0） |

</details>

<details>
<summary><b>事件 (4)</b></summary>

| 工具 | 說明 |
|------|------|
| `list_events` | 列出事件，支援篩選/排序/限制（v1.0.0） |
| `create_event` | 建立事件（支援提醒、地點、網址、個別時區） |
| `update_event` | 更新事件（含時區、重複規則、recurring span） |
| `delete_event` | 刪除事件 |

</details>

<details>
<summary><b>提醒事項 (7)</b></summary>

| 工具 | 說明 |
|------|------|
| `list_reminders` | 列出提醒事項，支援篩選/排序/限制、標籤解析（v1.0.0） |
| `create_reminder` | 建立提醒事項，支援到期日、標籤（v1.3.0） |
| `update_reminder` | 更新提醒事項（含標籤、`clear_due_date`）（v1.3.0） |
| `complete_reminder` | 標記為已完成/未完成 |
| `delete_reminder` | 刪除提醒事項 |
| `search_reminders` | 多關鍵字或標籤搜尋提醒事項（v1.3.0） |
| `list_reminder_tags` | 列出所有已使用的標籤及使用次數（v1.3.0） |

</details>

<details>
<summary><b>進階功能 (10)</b> ✨ v0.3.0+ 新增</summary>

| 工具 | 說明 |
|------|------|
| `search_events` | 多關鍵字搜尋事件，支援 AND/OR 匹配 |
| `list_events_quick` | 快速捷徑：`today`、`tomorrow`、`this_week`、`next_7_days` 等 |
| `create_events_batch` | 一次建立多個事件（支援個別時區） |
| `check_conflicts` | 檢查指定時間範圍是否有重疊事件 |
| `copy_event` | 複製事件到另一個日曆（可選擇移動） |
| `move_events_batch` | 批次移動事件到另一個日曆 |
| `delete_events_batch` | 依 ID 或日期範圍刪除事件，支援預覽模式（v1.0.0） |
| `find_duplicate_events` | 跨日曆查找重複事件（v0.5.0） |
| `create_reminders_batch` | 一次建立多個提醒事項（v0.9.0） |
| `delete_reminders_batch` | 批次刪除多個提醒事項（v0.9.0） |

</details>

<details>
<summary><b>復原/重做（3）</b> ✨ v1.4.0 新增</summary>

| 工具 | 說明 |
|------|------|
| `undo` | 復原最近一次行事曆/提醒事項操作 |
| `redo` | 重做上次復原的操作 |
| `undo_history` | 列出可復原的操作及時間戳記 |

</details>

---

## 安裝方式

### 系統需求

- macOS 13.0+
- Xcode 命令列工具（僅從原始碼編譯時需要）

### Claude Desktop

#### 方法 1：MCPB 一鍵安裝（推薦）

1. 從 [Releases](https://github.com/kiki830621/che-ical-mcp/releases) 下載 `che-ical-mcp.mcpb`
2. 雙擊 `.mcpb` 檔案安裝
3. 重新啟動 Claude Desktop

#### 方法 2：手動設定

1. 下載執行檔：
   ```bash
   curl -L https://github.com/kiki830621/che-ical-mcp/releases/latest/download/CheICalMCP -o /usr/local/bin/che-ical-mcp
   chmod +x /usr/local/bin/che-ical-mcp
   ```

2. 編輯 `~/Library/Application Support/Claude/claude_desktop_config.json`：
   ```json
   {
     "mcpServers": {
       "che-ical-mcp": {
         "command": "/usr/local/bin/che-ical-mcp"
       }
     }
   }
   ```

3. 重新啟動 Claude Desktop

### Claude Code (CLI)

```bash
# 建立 ~/bin（如果不存在）
mkdir -p ~/bin

# 下載執行檔
curl -L https://github.com/kiki830621/che-ical-mcp/releases/latest/download/CheICalMCP -o ~/bin/CheICalMCP
chmod +x ~/bin/CheICalMCP

# 註冊到 Claude Code（user scope = 所有專案都可使用）
claude mcp add --scope user --transport stdio che-ical-mcp -- ~/bin/CheICalMCP
```

### 從原始碼編譯（可選）

```bash
git clone https://github.com/kiki830621/che-ical-mcp.git
cd che-ical-mcp
make release && make install

# 複製到 ~/bin 並註冊
cp .build/release/CheICalMCP ~/bin/
claude mcp add --scope user --transport stdio che-ical-mcp -- ~/bin/CheICalMCP
```

### 授予權限

首次使用時，macOS 會詢問**行事曆**和**提醒事項**存取權限。請點選**允許**。

> **⚠️ macOS Sequoia (15.x) 注意事項：** 權限對話框會歸屬於**啟動 MCP server 的父程序**，而非 binary 本身。這代表：
>
> | 環境 | 權限歸屬 |
> |------|----------|
> | Claude Desktop | Claude Desktop.app ✅（自動彈出） |
> | Claude Code 在 **Terminal.app** | Terminal.app ✅（自動彈出） |
> | Claude Code 在 **VS Code** | VS Code ❌（可能不會彈出） |
> | Claude Code 在 **iTerm2** | iTerm2 ✅（自動彈出） |
>
> **如果權限對話框沒有出現**（VS Code 常見問題），需要在 VS Code 的 Info.plist 加入行事曆使用說明：
>
> ```bash
> # 加入行事曆使用說明到 VS Code
> /usr/libexec/PlistBuddy -c "Add :NSCalendarsFullAccessUsageDescription string 'VS Code needs calendar access for MCP extensions.'" \
>   "/Applications/Visual Studio Code.app/Contents/Info.plist"
> /usr/libexec/PlistBuddy -c "Add :NSRemindersFullAccessUsageDescription string 'VS Code needs reminders access for MCP extensions.'" \
>   "/Applications/Visual Studio Code.app/Contents/Info.plist"
>
> # 重新簽名 VS Code（修改 Info.plist 後必須執行）
> codesign -s - -f --deep "/Applications/Visual Studio Code.app"
>
> # 重新啟動 VS Code，權限對話框就會出現
> ```
>
> **注意：** VS Code 更新時此修改會被覆蓋，需要在每次更新後重新執行。

---

## v1.0.0 新功能

### 彈性日期解析

所有日期參數現在支援 4 種格式：

| 格式 | 範例 | 解釋 |
|------|------|------|
| 完整 ISO8601 | `"2026-02-06T14:00:00+08:00"` | 精確日期和時間（offset 保留） |
| 無時區 | `"2026-02-06T14:00:00"` | 使用事件 `timezone`（若有），否則系統時區 |
| 僅日期 | `"2026-02-06"` | 事件 `timezone` 或系統時區的午夜 |
| 僅時間 | `"14:00"` | 今天該時間 |

### 個別事件時區（v1.5.0）

為單一事件設定顯示時區 — 適用於多時區旅行行程。

```
「建立柏林時間 09:14 的航班」
→ create_event(title: "航班 LH123", start_time: "2026-04-08T09:14:00", timezone: "Europe/Berlin", ...)

「把飯店入住時間改成杜拜時區」
→ update_event(event_id: "...", timezone: "Asia/Dubai")

「移除事件的自訂時區」
→ update_event(event_id: "...", clear_timezone: true)
```

- **`timezone`** 接受 IANA 時區識別碼（如 `Europe/Berlin`、`America/New_York`、`Asia/Taipei`）
- 提供 `timezone` 時，無 offset 的時間字串會以該時區解釋
- 事件輸出的 `timezone` 欄位和 `start_date_local`/`end_date_local` 會使用事件自身時區
- 支援 `create_event`、`update_event`、`create_events_batch`
- 復原/重做會保留個別時區設定

### 事件參與者與組織者資訊

事件查詢工具（`list_events`、`search_events`、`list_events_quick`、`check_conflicts`）的回應中，現在包含參與者和組織者資訊。

#### `attendees`（陣列，選填）

事件有參與者時出現。每個 attendee 物件包含：

| 欄位 | 類型 | 說明 |
|------|------|------|
| `name` | 字串或 null | 顯示名稱，不在通訊錄中時為 null |
| `email` | 字串 | 從參與者 URL 提取的電子郵件 |
| `role` | 字串 | `unknown`、`required`、`optional`、`chair`、`non_participant` 之一 |
| `status` | 字串 | `unknown`、`pending`、`accepted`、`declined`、`tentative`、`delegated`、`completed`、`in_process` 之一 |
| `type` | 字串 | `unknown`、`person`、`room`、`resource`、`group` 之一 |
| `is_current_user` | 布林值 | 是否為目前使用者 |

#### `organizer`（物件，選填）

事件有組織者時出現。包含：

| 欄位 | 類型 | 說明 |
|------|------|------|
| `name` | 字串或 null | 顯示名稱 |
| `email` | 字串 | 電子郵件 |
| `is_current_user` | 布林值 | 組織者是否為目前使用者 |

> **注意：** Attendees 和 organizer 為**唯讀**欄位（EventKit 限制）。事件沒有參與者或組織者時省略這些欄位（例如本地行事曆事件）。

### 模糊行事曆匹配

行事曆名稱現在**不區分大小寫**匹配。如果找不到，錯誤訊息會列出所有可用的行事曆。

### 增強的列出/刪除工具

- **`list_events`**：`filter`（all/past/future/all_day）、`sort`（asc/desc）、`limit`
- **`list_reminders`**：`filter`（all/incomplete/completed/overdue）、`sort`（due_date/creation_date/priority/title）、`limit`
- **`delete_events_batch`**：日期範圍模式（`before_date`/`after_date`）+ `dry_run` 預覽

> **重大變更**：`list_events` 和 `list_reminders` 現在回傳 `{events/reminders: [...], metadata: {...}}` 而非純陣列。

---

## 使用範例

### 行事曆管理

```
「列出我所有的行事曆」
「下週有什麼行程？」
「明天下午 2 點建立一個標題為『團隊同步』的會議」
「星期五早上 10 點加一個牙醫預約，地點是『台北市信義路 123 號』」
「刪除『已取消的會議』這個事件」
```

### 提醒事項管理

```
「列出我未完成的提醒事項」
「顯示購物清單中的所有提醒事項」
「新增提醒事項：買牛奶」
「建立一個明天下午 5 點打電話給媽媽的提醒」
「將『買牛奶』標記為已完成」
「刪除關於雜貨的提醒事項」
```

### 進階功能（v0.3.0+）

```
「搜尋包含『會議』的事件」
「搜尋同時包含『專案』和『審查』的事件」
「今天有什麼行程？」
「顯示這週的行程」
「如果我在下午 2-3 點安排會議，會有衝突嗎？」
「幫我建立接下來 3 週的週會」
「把牙醫預約複製到工作行事曆」
「把舊行事曆的所有事件移到新行事曆」
「刪除所有已取消的事件」
「找出『IDOL』和『Idol』行事曆中的重複事件」
```

### 開發體驗改進（v1.0.0）

```
「顯示我接下來 5 個事件」
→ list_events(start_date: "2026-02-06", end_date: "2026-12-31", filter: "future", sort: "asc", limit: 5)

「顯示我逾期的提醒事項」
→ list_reminders(filter: "overdue")

「預覽刪除『舊行事曆』2025 年之前的事件」
→ delete_events_batch(calendar_name: "舊行事曆", before_date: "2025-01-01", dry_run: true)

「下午 2 點建立事件」（不需要完整 ISO8601！）
→ create_event(start_time: "14:00", end_time: "15:00", ...)
```

---

## 支援的行事曆來源

支援任何同步到 macOS 行事曆 App 的行事曆：

- iCloud 行事曆
- Google 日曆
- Microsoft Outlook/Exchange
- CalDAV 行事曆
- 本機行事曆

### 同名日曆消歧義（v0.6.0+）

如果你有來自不同來源的同名日曆（例如 iCloud 和 Google 都有「工作」日曆），可以使用 `calendar_source` 參數：

```
「在 iCloud 的工作日曆建立事件」
→ create_event(calendar_name: "工作", calendar_source: "iCloud", ...)

「顯示 Google 工作日曆的事件」
→ list_events(calendar_name: "工作", calendar_source: "Google", ...)
```

如果偵測到歧義，錯誤訊息會列出所有可用的來源。

---

## 疑難排解

| 問題 | 解決方法 |
|------|----------|
| Server disconnected | 重新編譯 `make release && make install` |
| 權限被拒絕 | 在系統設定 > 隱私權與安全性中授予行事曆/提醒事項存取權限 |
| 權限對話框沒有出現 | 參考[授予權限](#授予權限)中的 macOS Sequoia 解決方案 |
| **SSH 連線時權限被拒** | 參考下方 [SSH 存取](#ssh-存取) |
| 找不到行事曆 | 確認行事曆在 macOS 行事曆 App 中可見 |
| 提醒事項未同步 | 在系統設定中檢查 iCloud 同步 |

### SSH 存取

macOS TCC（透明度、同意與控制）的隱私權限是**依應用程式**授予的。SSH session 跑在 `sshd` 底下，是不同的安全環境 — 因此在本機授予 Terminal 或 Claude Code 的權限**不會**延伸到 SSH。

**方法 A — 先在本機執行一次（建議）：**
1. 在目標 Mac 上**本機**（非 SSH）執行一次 `CheICalMCP`
2. TCC 對話框出現時授予行事曆和提醒事項存取權限
3. 之後 SSH session 應能沿用該 binary 的授權

**方法 B — 授予 sshd 完整磁碟存取權限：**
1. 打開**系統設定 → 隱私權與安全性 → 完整磁碟存取權限**
2. 點 **+**，按 <kbd>⌘</kbd><kbd>⇧</kbd><kbd>G</kbd>，輸入 `/usr/sbin/sshd` 加入
3. 重新建立 SSH 連線

> ⚠️ 方法 B 會授予 `sshd` 廣泛的檔案存取權限 — 請僅在完全由你控管的機器上使用。

---

## 技術細節

- **目前版本**：v1.7.0
- **框架**：[MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) v0.12.0
- **行事曆 API**：EventKit（原生 macOS 框架）
- **傳輸**：stdio
- **平台**：macOS 13.0+（Ventura 及更新版本）
- **工具數量**：28 個工具，涵蓋行事曆、事件、提醒事項、標籤、復原/重做和進階操作

---

## 版本歷史

| 版本 | 變更 |
|------|------|
| v1.7.0 | **事件參與者與組織者資訊**（#17）：事件回傳新增唯讀 `attendees` 陣列和 `organizer` 物件。重構共用 `formatEventDict` 方法。 |
| v1.6.0 | **`--setup` 旗標**（#13）：預授權 TCC 權限，支援 launchd/自動化環境。非互動 session 偵測（TERM + ppid）。SSH+launchd 合併錯誤訊息。**`--cli` 模式**（#14）：無需 MCP server 直接呼叫全部 28 個工具。支援 flag-based（`--key value`）和 JSON stdin 兩種模式。智慧型別推論（bool/int/double/array）。MCP Swift SDK 0.12.0（Swift 6.3 相容）。 |
| v1.5.0 | **個別事件時區**（#12）：`create_event`/`update_event`/`create_events_batch` 支援 `timezone` 參數，事件輸出使用事件自身時區，無 offset 時間以事件時區解析。**清除到期日**（#9）：`update_reminder` 新增 `clear_due_date`。**星期驗證**（#5）：`create_event`/`update_event` 驗證 `start_time` 星期是否匹配 `days_of_week`。**復原/重做**（#8）：3 個新工具（`undo`、`redo`、`undo_history`）。**週期事件修正**（#7）：支援 `occurrence_date` 的 occurrence 級別刪除/更新。**Swift 6 建置**（#11）：README 改為 `make release` 流程 |
| v1.4.0 | **LLM 可靠性**：修正預設搜尋範圍（±2 年取代 distantPast/Future）、`search_events` 回傳 `searched_range` metadata、`create_events_batch` 回傳 `similar_events` 提示、tool description 加入 LLM 使用指引 |
| v1.3.1 | **文檔修正**：明確說明標籤為 MCP 層級（非 Reminders.app 原生標籤）；Apple 未提供原生標籤的公開 API |
| v1.3.0 | **提醒事項標籤**（MCP 層級）：`create_reminder`/`update_reminder`/`create_reminders_batch` 支援 `#hashtag` 標籤文字存於備註，`search_reminders` 可依標籤過濾，新增 `list_reminder_tags` 工具；MCP SDK 0.11.0。注意：標籤可透過 MCP 搜尋，但不會成為 Reminders.app 原生標籤（Apple 未提供公開 API） |
| v1.2.0 | **冪等寫入**：`create_event`、`create_events_batch`、`create_reminder`、`create_reminders_batch`、`create_calendar` 寫入前自動查重，防止 Agent 重試產生重複資料；回傳包含 `skipped` 計數 |
| v1.1.0 | **循環規則 + 位置**：循環事件/提醒（每日/每週/每月/每年）、含座標結構化位置、基於地理圍欄的位置提醒觸發、豐富的循環規則輸出 |
| v1.0.0 | **開發體驗改進**：彈性日期解析（4 種格式）、模糊日曆匹配、`list_events`/`list_reminders` 篩選/排序/限制、`delete_events_batch` 預覽模式 + 日期範圍模式 |
| v0.9.0 | **4 個新工具**（20→24）：`update_calendar`、`search_reminders`、`create_reminders_batch`、`delete_reminders_batch` |
| v0.8.2 | **國際化週支援**：`list_events_quick` 新增 `week_starts_on` 參數（monday/sunday/saturday/system） |
| v0.8.1 | **修復**：`update_event` 時間驗證 Bug，移動事件時自動保留持續時間 |
| v0.8.0 | **重大變更**：`calendar_name` 現在是建立操作的必填欄位（移除隱式默認） |
| v0.7.0 | **工具標註**：支援 Anthropic Connectors Directory、自動刷新機制、改進批次工具說明 |
| v0.6.0 | **來源消歧義**：`calendar_source` 參數支援同名日曆區分 |
| v0.5.0 | 批次刪除、重複偵測、多關鍵字搜尋、改善權限錯誤、新增 PRIVACY.md |
| v0.4.0 | 事件複製/移動：`copy_event`、`move_events_batch` |
| v0.3.0 | 進階功能：搜尋、快速範圍、批次建立、衝突檢查、時區顯示 |
| v0.2.0 | Swift 重寫，完整支援提醒事項 |
| v0.1.x | Python 版本（已棄用） |

---

## 貢獻

歡迎貢獻！請隨時提交 Pull Request。

---

## 授權

MIT License - 詳見 [LICENSE](LICENSE)。

---

## 作者

由 **鄭澈** ([@kiki830621](https://github.com/kiki830621)) 建立

如果覺得有用，請給個 Star 支持一下！
