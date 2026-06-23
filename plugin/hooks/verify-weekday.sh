#!/bin/bash
# PreToolUse hook: verify day-of-week for calendar events
# Reads tool_input from stdin, extracts date, outputs weekday info
# so the LLM can cross-check against the user's stated day-of-week.

INPUT=$(cat)

# Extract start_time from tool input (ISO8601 format)
START_TIME=$(echo "$INPUT" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    inp = d.get('tool_input', {})
    t = inp.get('start_time', inp.get('end_time', ''))
    print(t)
except:
    pass
" 2>/dev/null)

if [ -z "$START_TIME" ]; then
    exit 0
fi

# Extract date part (YYYY-MM-DD) from ISO8601
DATE_PART=$(echo "$START_TIME" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')

if [ -z "$DATE_PART" ]; then
    exit 0
fi

# Calculate day of week
# Force English weekday name regardless of locale
WEEKDAY_EN=$(LANG=en_US.UTF-8 date -j -f "%Y-%m-%d" "$DATE_PART" "+%A" 2>/dev/null)
WEEKDAY_NUM=$(date -j -f "%Y-%m-%d" "$DATE_PART" "+%u" 2>/dev/null)

# Chinese weekday (bash 3.2 compatible)
case "$WEEKDAY_NUM" in
    1) WEEKDAY_ZH="週一" ;; 2) WEEKDAY_ZH="週二" ;; 3) WEEKDAY_ZH="週三" ;;
    4) WEEKDAY_ZH="週四" ;; 5) WEEKDAY_ZH="週五" ;; 6) WEEKDAY_ZH="週六" ;;
    7) WEEKDAY_ZH="週日" ;; *) WEEKDAY_ZH="" ;;
esac

# Japanese weekday
case "$WEEKDAY_NUM" in
    1) WEEKDAY_JA="月曜日" ;; 2) WEEKDAY_JA="火曜日" ;; 3) WEEKDAY_JA="水曜日" ;;
    4) WEEKDAY_JA="木曜日" ;; 5) WEEKDAY_JA="金曜日" ;; 6) WEEKDAY_JA="土曜日" ;;
    7) WEEKDAY_JA="日曜日" ;; *) WEEKDAY_JA="" ;;
esac

# Extract event title for context
TITLE=$(echo "$INPUT" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('tool_input', {}).get('title', ''))
except:
    pass
" 2>/dev/null)

# Detect locale for output language
LOCALE="${LANG:-en_US.UTF-8}"
case "$LOCALE" in
    zh_TW*|zh_HK*)
        echo "⚠️ 日期驗證: ${DATE_PART} 是 ${WEEKDAY_ZH} (${WEEKDAY_EN})。請確認這與用戶要求的星期一致。事件: ${TITLE}"
        ;;
    zh_CN*)
        echo "⚠️ 日期验证: ${DATE_PART} 是 ${WEEKDAY_ZH} (${WEEKDAY_EN})。请确认这与用户要求的星期一致。事件: ${TITLE}"
        ;;
    ja_JP*)
        echo "⚠️ 曜日検証: ${DATE_PART} は ${WEEKDAY_JA} (${WEEKDAY_EN}) です。ユーザーの指定した曜日と一致しているか確認してください。イベント: ${TITLE}"
        ;;
    *)
        echo "⚠️ Day-of-week check: ${DATE_PART} is ${WEEKDAY_EN} (${WEEKDAY_ZH}). Verify this matches the user's intended day. Event: ${TITLE}"
        ;;
esac
