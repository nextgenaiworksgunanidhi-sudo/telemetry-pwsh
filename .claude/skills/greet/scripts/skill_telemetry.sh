#!/usr/bin/env bash
# skill_telemetry.sh — Send an OTLP span to Jaeger for a Claude Skill invocation.
# Requires: bash 4+, curl, openssl, python3
set -uo pipefail

# ---------------------------------------------------------------------------
# Parameter parsing  (-SkillName "greet" style, same as the PS1 version)
# ---------------------------------------------------------------------------

SKILL_NAME="unknown"
USER_PROMPT=""
COMMAND_FILE=""
LLM_RESPONSE=""
OTEL_ENDPOINT="http://localhost:4318/v1/traces"
TRACE_ID=""
PARENT_SPAN_ID=""
EXTRA_ATTRIBUTES="{}"
START_TIME_UNIX_NANO=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -SkillName)         SKILL_NAME="$2";          shift 2 ;;
        -UserPrompt)        USER_PROMPT="$2";         shift 2 ;;
        -CommandFile)       COMMAND_FILE="$2";        shift 2 ;;
        -LlmResponse)       LLM_RESPONSE="$2";        shift 2 ;;
        -OtelEndpoint)      OTEL_ENDPOINT="$2";       shift 2 ;;
        -TraceId)           TRACE_ID="$2";            shift 2 ;;
        -ParentSpanId)      PARENT_SPAN_ID="$2";      shift 2 ;;
        -ExtraAttributes)   EXTRA_ATTRIBUTES="$2";    shift 2 ;;
        -StartTimeUnixNano) START_TIME_UNIX_NANO="$2"; shift 2 ;;
        *) shift ;;
    esac
done

# ---------------------------------------------------------------------------
# Helpers — IDs and time
# ---------------------------------------------------------------------------

new_trace_id() { openssl rand -hex 16; }
new_span_id()  { openssl rand -hex 8; }

get_unix_nano() {
    python3 -c "import time; print(int(time.time() * 1e9))"
}

# ---------------------------------------------------------------------------
# User identity
# ---------------------------------------------------------------------------

get_user_identity() {
    USER_LOGIN="${USER:-$(id -un 2>/dev/null || echo "unknown")}"
    USER_GIT_EMAIL="$(git config user.email 2>/dev/null || echo "")"
    USER_GIT_NAME="$(git config user.name 2>/dev/null || echo "")"
}

# ---------------------------------------------------------------------------
# Environment detection
# ---------------------------------------------------------------------------

get_client_env() {
    if [[ "${TERM_PROGRAM:-}" == "vscode" || -n "${VSCODE_IPC_HOOK_CLI:-}" || -n "${VSCODE_PID:-}" ]]; then
        echo "vscode"
    else
        echo "cli"
    fi
}

# ---------------------------------------------------------------------------
# Command execution — captures stdout + stderr, handles errors
# ---------------------------------------------------------------------------

SKILL_OUTPUT=""
SKILL_SUCCEEDED="true"
SKILL_ERROR=""

invoke_skill_command() {
    local cmd_file="$1"

    # CommandFile is optional — skip execution if not provided
    [[ -z "$cmd_file" ]] && return

    local allowed_base
    allowed_base="$(realpath ".claude/skills" 2>/dev/null || echo "")"
    local resolved
    resolved="$(realpath "$cmd_file" 2>/dev/null || echo "")"

    if [[ -z "$resolved" || ! -f "$resolved" ]]; then
        SKILL_SUCCEEDED="false"; SKILL_ERROR="CommandFile not found: $cmd_file"; return
    fi
    if [[ -z "$allowed_base" || "$resolved" != "$allowed_base"/* ]]; then
        SKILL_SUCCEEDED="false"; SKILL_ERROR="CommandFile outside allowed directory: $cmd_file"; return
    fi

    set +e
    SKILL_OUTPUT=$(bash "$resolved" 2>&1)
    local exit_code=$?
    set -e

    if [[ $exit_code -ne 0 ]]; then
        SKILL_SUCCEEDED="false"
        SKILL_ERROR="Command exited with code $exit_code: $SKILL_OUTPUT"
    fi
}

# ---------------------------------------------------------------------------
# OTLP JSON builder — uses Python for safe string escaping
# ---------------------------------------------------------------------------

build_otlp_json() {
    SKILL_NAME="$SKILL_NAME" \
    USER_PROMPT="$USER_PROMPT" \
    LLM_RESPONSE="$LLM_RESPONSE" \
    SKILL_OUTPUT="$SKILL_OUTPUT" \
    CLIENT_ENV="$CLIENT_ENV" \
    SKILL_SUCCEEDED="$SKILL_SUCCEEDED" \
    SKILL_ERROR="$SKILL_ERROR" \
    EXTRA_ATTRIBUTES="$EXTRA_ATTRIBUTES" \
    TRACE_ID="$TRACE_ID" \
    SPAN_ID="$SPAN_ID" \
    PARENT_SPAN_ID="$PARENT_SPAN_ID" \
    SKILL_NAME_ENV="$SKILL_NAME" \
    START_NANO="$START_NANO" \
    END_NANO="$END_NANO" \
    SKILL_TELEMETRY_TRUNCATE="${SKILL_TELEMETRY_TRUNCATE:-300}" \
    USER_LOGIN="$USER_LOGIN" \
    USER_GIT_EMAIL="$USER_GIT_EMAIL" \
    USER_GIT_NAME="$USER_GIT_NAME" \
    python3 - <<'PYEOF'
import json, os

TRUNCATE_LIMIT = int(os.environ.get("SKILL_TELEMETRY_TRUNCATE", "300"))

def truncate(val):
    s = str(val)
    return s if len(s) <= TRUNCATE_LIMIT else s[:TRUNCATE_LIMIT] + "...[truncated]"

def attr(key, val):
    return {"key": key, "value": {"stringValue": str(val)}}

e = os.environ
succeeded = e["SKILL_SUCCEEDED"] == "true"

attrs = [
    attr("skill.name",     e["SKILL_NAME"]),
    attr("skill.prompt",   truncate(e["USER_PROMPT"])),
    attr("skill.response", truncate(e["LLM_RESPONSE"])),
    attr("client.env",     e["CLIENT_ENV"]),
    attr("skill.success",  e["SKILL_SUCCEEDED"]),
    attr("user.login",     e["USER_LOGIN"]),
]

if e.get("SKILL_OUTPUT"):
    attrs.append(attr("skill.output", truncate(e["SKILL_OUTPUT"])))

if e.get("USER_GIT_NAME"):
    attrs.append(attr("user.git_name",  e["USER_GIT_NAME"]))
if e.get("USER_GIT_EMAIL"):
    attrs.append(attr("user.git_email", e["USER_GIT_EMAIL"]))

if e.get("SKILL_ERROR"):
    attrs.append(attr("skill.error", e["SKILL_ERROR"]))

try:
    for k, v in json.loads(e.get("EXTRA_ATTRIBUTES", "{}")).items():
        attrs.append(attr(k, str(v)))
except Exception:
    pass

status_code = 1 if succeeded else 2
status_msg  = "OK" if succeeded else e.get("SKILL_ERROR", "error")

span = {
    "traceId":           e["TRACE_ID"],
    "spanId":            e["SPAN_ID"],
    "name":              f"skill.{e['SKILL_NAME']}",
    "kind":              2,
    "startTimeUnixNano": e["START_NANO"],
    "endTimeUnixNano":   e["END_NANO"],
    "attributes":        attrs,
    "status":            {"code": status_code, "message": status_msg},
}

if e.get("PARENT_SPAN_ID"):
    span["parentSpanId"] = e["PARENT_SPAN_ID"]

payload = {
    "resourceSpans": [{
        "resource": {
            "attributes": [
                attr("service.name",    "claude-skills"),
                attr("service.version", "1.0.0"),
                attr("telemetry.sdk",   "claude-skill-telemetry-bash"),
            ]
        },
        "scopeSpans": [{
            "scope": {"name": "claude-skills-telemetry", "version": "1.0.0"},
            "spans": [span],
        }],
    }]
}

print(json.dumps(payload))
PYEOF
}

# ---------------------------------------------------------------------------
# Transport — OTLP HTTP with .jsonl fallback
# ---------------------------------------------------------------------------

send_otlp_payload() {
    local endpoint="$1"
    local body="$2"

    curl --silent --show-error --max-time 5 \
        --request POST "$endpoint" \
        --header "Content-Type: application/json" \
        --data "$body" \
        > /dev/null 2>&1
}

write_fallback_log() {
    local body="$1"
    local log_path="${TMPDIR:-/tmp}/claude-skills-telemetry.jsonl"
    echo "$body" >> "$log_path"
    echo "Telemetry offline — written to $log_path" >&2
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

START_NANO="${START_TIME_UNIX_NANO:-$(get_unix_nano)}"
TRACE_ID="${TRACE_ID:-$(new_trace_id)}"
SPAN_ID="$(new_span_id)"
CLIENT_ENV="$(get_client_env)"
get_user_identity

invoke_skill_command "$COMMAND_FILE"
END_NANO="$(get_unix_nano)"

JSON="$(build_otlp_json)"

if send_otlp_payload "$OTEL_ENDPOINT" "$JSON"; then
    echo "Telemetry sent to $OTEL_ENDPOINT"
else
    write_fallback_log "$JSON"
fi

# Surface skill errors to caller after telemetry is recorded
if [[ "$SKILL_SUCCEEDED" == "false" ]]; then
    echo "Skill command failed: $SKILL_ERROR" >&2
    exit 1
fi
