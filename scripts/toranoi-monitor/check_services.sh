#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/.env"

STATE_FILE="/tmp/toranoi_service_state"

OLLAMA_STATUS=$(systemctl is-active ollama)
WEBUI_STATUS=$(docker inspect -f '{{.State.Status}}' open-webui 2>/dev/null || echo "missing")
LAST_COMPUTE_LINE=$(journalctl -u ollama --no-pager | grep "inference compute" | tail -1)

if echo "$LAST_COMPUTE_LINE" | grep -q "library=cpu"; then
    ROCM_STATUS="fallback"
else
    ROCM_STATUS="ok"
fi

send_alert() {
    local service="$1"
    local status="$2"
    curl -s -H "Content-Type: application/json" \
        -d "{\"content\": \"⚠️ **${service}** が停止しています(状態: ${status})\"}" \
        "$WEBHOOK_URL" > /dev/null
}

send_rocm_alert() {
    curl -s -H "Content-Type: application/json" \
        -d "{\"content\": \"🔴 **ROCmがCPUフォールバックしました**。GPU認識に失敗している可能性があります。\`journalctl -u ollama | grep inference\`で確認してください。\"}" \
        "$WEBHOOK_URL" > /dev/null
}

touch "$STATE_FILE"
PREV_OLLAMA=$(grep "^ollama=" "$STATE_FILE" | cut -d= -f2)
PREV_WEBUI=$(grep "^webui=" "$STATE_FILE" | cut -d= -f2)
PREV_ROCM=$(grep "^rocm=" "$STATE_FILE" | cut -d= -f2)

if [ "$OLLAMA_STATUS" != "active" ]; then
    if [ "$PREV_OLLAMA" == "active" ] || [ -z "$PREV_OLLAMA" ]; then
        send_alert "Ollama" "$OLLAMA_STATUS"
    fi
fi

if [ "$WEBUI_STATUS" != "running" ]; then
    if [ "$PREV_WEBUI" == "running" ] || [ -z "$PREV_WEBUI" ]; then
        send_alert "Open WebUI" "$WEBUI_STATUS"
    fi
fi

if [ "$ROCM_STATUS" == "fallback" ]; then
    if [ "$PREV_ROCM" == "ok" ] || [ -z "$PREV_ROCM" ]; then
        send_rocm_alert
    fi
fi

echo "ollama=$OLLAMA_STATUS" > "$STATE_FILE"
echo "webui=$WEBUI_STATUS" >> "$STATE_FILE"
echo "rocm=$ROCM_STATUS" >> "$STATE_FILE"
