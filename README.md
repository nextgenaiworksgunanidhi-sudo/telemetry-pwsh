# Claude Skills Telemetry

OpenTelemetry telemetry library for Claude Skills running in VS Code with GitHub Copilot.
Sends OTLP spans to a local Jaeger instance — one reusable script, zero boilerplate per skill.

---

## What it does

Every time a Claude Skill is invoked, the telemetry script:
- Records start/end time (duration of the skill)
- Captures the user prompt, LLM response, and skill output (if any)
- Detects whether the skill ran in VS Code or CLI
- Captures user identity (system login, git name, git email)
- Sends an OTLP span to Jaeger via HTTP
- Falls back to a local `.jsonl` file if the endpoint is unreachable
- Records errors as span status `ERROR` — telemetry always fires even on failure

---

## Architecture

```
GitHub Copilot Chat
  └── reads .claude/skills/<skill>/SKILL.md
        └── LLM responds to user
              └── calls skill_telemetry.sh / skill_telemetry.ps1
                    └── sends OTLP span → Jaeger (service: claude-skills)
                          └── fallback → $TMPDIR/claude-skills-telemetry.jsonl
```

---

## Deliverables

| File | Platform | Purpose |
|---|---|---|
| `skill_telemetry.sh` | Mac / Linux | Reusable telemetry library |
| `skill_telemetry.ps1` | Windows (pwsh) | Reusable telemetry library |

Both scripts are drop-in — place them in `.claude/skills/<skill>/scripts/` and call them from `SKILL.md`.

---

## Span Attributes

Every span sent to Jaeger contains:

| Attribute | Description | Always present |
|---|---|---|
| `skill.name` | Name of the skill | Yes |
| `skill.prompt` | User's prompt (verbatim, max 300 chars) | Yes |
| `skill.response` | LLM response (verbatim, max 300 chars) | Yes |
| `skill.success` | `true` or `false` | Yes |
| `client.env` | `vscode` or `cli` | Yes |
| `user.login` | System username | Yes |
| `user.git_name` | Git config `user.name` | If configured |
| `user.git_email` | Git config `user.email` | If configured |
| `skill.output` | Script output if `-CommandFile` used (max 300 chars) | If CommandFile provided |
| `skill.error` | Error message if skill failed | If failed |

---

## Prerequisites

### Mac / Linux
- `bash` 4+
- `curl`
- `openssl`
- `python3`

### Windows
- `pwsh` (PowerShell 7+) — install from [PowerShell releases](https://github.com/PowerShell/PowerShell/releases/latest)
- `curl`

### Jaeger (local)
```bash
docker run -d --name jaeger \
  -p 16686:16686 \
  -p 4318:4318 \
  jaegertracing/all-in-one:latest
```

---

## Integration Guide

### Step 1 — Copy the script into your skill

```
.claude/skills/<your-skill>/
  SKILL.md
  scripts/
    skill_telemetry.sh      ← copy here (Mac/Linux)
    skill_telemetry.ps1     ← copy here (Windows)
```

### Step 2 — Add one line to SKILL.md

```markdown
---
name: <your-skill>
description: <description>
argument-hint: <hint>
user-invocable: true
---

## Instructions

<your skill instructions here>

Then run:
```bash
bash .claude/skills/<your-skill>/scripts/skill_telemetry.sh -SkillName "<your-skill>" -UserPrompt "<USER_PROMPT>" -LlmResponse "<RESPONSE>"
```

> `USER_PROMPT` and `RESPONSE` must be verbatim, max 200 chars, never paraphrased.
```

That's it. No other changes needed.

---

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `-SkillName` | Yes | Name of the skill (e.g. `greet`) |
| `-UserPrompt` | Yes | Exact user message, max 200 chars |
| `-LlmResponse` | Yes | Exact LLM response, max 200 chars |
| `-CommandFile` | No | Path to a script to execute (see below) |
| `-OtelEndpoint` | No | OTLP endpoint (default: `http://localhost:4318/v1/traces`) |
| `-TraceId` | No | Custom trace ID (auto-generated if omitted) |
| `-ParentSpanId` | No | Parent span ID for trace linking |
| `-ExtraAttributes` | No | JSON object of additional attributes (e.g. `{"env":"prod"}`) |
| `-StartTimeUnixNano` | No | Pre-measured start time in Unix nanoseconds |

---

## LLM-only skills vs Script-backed skills

### LLM-only skill (no CommandFile needed)
The LLM is the logic. Just record what happened.

```bash
bash .claude/skills/greet/scripts/skill_telemetry.sh \
  -SkillName "greet" \
  -UserPrompt "greet John" \
  -LlmResponse "Hello, John! Hope you are having a great day."
```

`skill.output` will not appear in the span.

### Script-backed skill (with CommandFile)
The skill runs a real script (API call, file processing, query, etc.).

```bash
bash .claude/skills/fetch/scripts/skill_telemetry.sh \
  -SkillName "fetch" \
  -UserPrompt "fetch weather London" \
  -CommandFile ".claude/skills/fetch/scripts/fetch_logic.sh" \
  -LlmResponse "It is 22°C in London today."
```

`skill.output` will contain the script's stdout (truncated to 300 chars).

> **Security:** `-CommandFile` path is validated to stay within `.claude/skills/`.
> Path traversal attempts (e.g. `/etc/passwd`) are blocked and recorded as errors.

---

## Truncation

Long values are automatically truncated to prevent Jaeger storage bloat:

| Field | Default limit | Override |
|---|---|---|
| `skill.prompt` | 300 chars | `SKILL_TELEMETRY_TRUNCATE=500 bash skill_telemetry.sh ...` |
| `skill.response` | 300 chars | Same env var |
| `skill.output` | 300 chars | Same env var |

SKILL.md instructs the LLM to pre-truncate to 200 chars before passing as arguments.

---

## Fallback logging

If the OTLP endpoint is unreachable, the full span payload is written to:

| Platform | Path |
|---|---|
| Mac / Linux | `$TMPDIR/claude-skills-telemetry.jsonl` |
| Windows | `$env:TEMP\claude-skills-telemetry.jsonl` |

Each line is a complete, valid OTLP JSON payload that can be replayed later.

---

## Verify in Jaeger

```bash
# Check service is registered
curl http://localhost:16686/api/services

# Fetch latest trace
curl "http://localhost:16686/api/traces?service=claude-skills&limit=1"

# Open Jaeger UI
open http://localhost:16686
```

---

## Security

| Risk | Mitigation |
|---|---|
| Shell injection via `-Command` | `-Command` removed entirely — no `eval` or `Invoke-Expression` |
| Path traversal via `-CommandFile` | Path resolved and validated within `.claude/skills/` |
| PII in telemetry | `user.git_email` captured — hash or remove for GDPR compliance in prod |
| Plaintext transport | Use HTTPS endpoint in production |

---

## Production considerations

Before going to production:

- Replace Jaeger all-in-one with a persistent OTEL backend (Grafana Tempo, Honeycomb, Datadog)
- Switch endpoint to HTTPS and add API key via `-OtelEndpoint` and `-ExtraAttributes`
- Hash or remove `user.git_email` for GDPR compliance
- Add retry logic and fallback log rotation
- Add sampling for high-volume skills

---

## Jaeger span example

```
Service:  claude-skills
Operation: skill.greet
Duration:  75ms

Attributes:
  skill.name      greet
  skill.prompt    greet John
  skill.response  Hello, John! Hope you are having a great day.
  skill.success   true
  client.env      vscode
  user.login      gunanidhi
  user.git_name   Gunanidhi
  user.git_email  gunanidhi@example.com
```

---

## Version history

| Version | Changes |
|---|---|
| `v1.0.0` | Initial release — bash + PowerShell telemetry library, user identity, optional CommandFile, truncation, fallback logging, shell injection protection |

---

## Contributing

1. Fork the repo
2. Add your skill under `.claude/skills/<skill-name>/`
3. Drop `skill_telemetry.sh` into `scripts/`
4. Add the one-line telemetry call to `SKILL.md`
5. Open a PR
