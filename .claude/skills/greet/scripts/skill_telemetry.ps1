#Requires -Version 7.0
<#
.SYNOPSIS
    Sends an OTLP span to Jaeger for a Claude Skill invocation.
.EXAMPLE
    pwsh skill_telemetry.ps1 -SkillName "greet" -UserPrompt "greet John" `
        -CommandFile ".claude/skills/greet/scripts/greet_logic.ps1" -LlmResponse "Hello, John!"
#>
param(
    [string]$SkillName          = "unknown",
    [string]$UserPrompt         = "",
    [string]$CommandFile        = "",
    [string]$LlmResponse        = "",
    [string]$OtelEndpoint       = "http://localhost:4318/v1/traces",
    [string]$TraceId            = "",
    [string]$ParentSpanId       = "",
    [string]$ExtraAttributes    = "{}",
    [string]$StartTimeUnixNano  = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Helpers — IDs and time
# ---------------------------------------------------------------------------

function New-TraceId {
    $bytes = [byte[]]::new(16)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return ($bytes | ForEach-Object { $_.ToString("x2") }) -join ""
}

function New-SpanId {
    $bytes = [byte[]]::new(8)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return ($bytes | ForEach-Object { $_.ToString("x2") }) -join ""
}

function Get-UnixNano {
    return [string]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() * 1000000L)
}

# ---------------------------------------------------------------------------
# Environment detection
# ---------------------------------------------------------------------------

function Get-ClientEnvironment {
    $termProg  = $env:TERM_PROGRAM
    $ipcHook   = $env:VSCODE_IPC_HOOK_CLI
    $vscodePid = $env:VSCODE_PID
    if ($termProg -eq "vscode" -or $ipcHook -or $vscodePid) { return "vscode" }
    return "cli"
}

function Get-UserIdentity {
    $login    = if ($env:USERNAME) { $env:USERNAME } else { $env:USER }
    $gitName  = & git config user.name  2>$null
    $gitEmail = & git config user.email 2>$null
    return [PSCustomObject]@{
        Login    = if ($login)    { $login }    else { "unknown" }
        GitName  = if ($gitName)  { $gitName }  else { "" }
        GitEmail = if ($gitEmail) { $gitEmail } else { "" }
    }
}

# ---------------------------------------------------------------------------
# Command execution
# Validates CommandFile is within .claude/skills/ before running.
# No Invoke-Expression — eliminates shell injection risk entirely.
# ---------------------------------------------------------------------------

function Invoke-SkillCommand {
    param([string]$CmdFile)

    $succeeded  = $true
    $errMsg     = $null
    $output     = $null

    $allowedBase = (Resolve-Path ".claude/skills" -EA SilentlyContinue)?.Path
    $resolved    = (Resolve-Path $CmdFile -EA SilentlyContinue)?.Path

    if (-not $resolved -or -not (Test-Path $resolved)) {
        return [PSCustomObject]@{ Succeeded = $false; Output = ""; ErrorMsg = "CommandFile not found: $CmdFile" }
    }
    if (-not $allowedBase -or -not $resolved.StartsWith($allowedBase)) {
        return [PSCustomObject]@{ Succeeded = $false; Output = ""; ErrorMsg = "CommandFile outside allowed directory: $CmdFile" }
    }

    try {
        $output = & pwsh -NoProfile -File $resolved 6>&1 2>&1
    } catch {
        $succeeded = $false
        $errMsg    = $_.Exception.Message
    }

    $outputStr = ($output | ForEach-Object { "$_" }) -join "`n"

    return [PSCustomObject]@{
        Succeeded = $succeeded
        Output    = $outputStr.Trim()
        ErrorMsg  = $errMsg
    }
}

# ---------------------------------------------------------------------------
# OTLP payload builders
# ---------------------------------------------------------------------------

function New-StringAttr {
    param([string]$Key, [string]$Val)
    return [PSCustomObject]@{ key = $Key; value = [PSCustomObject]@{ stringValue = $Val } }
}

function New-OtlpAttributes {
    param(
        [string]$SkillName, [string]$UserPrompt, [string]$LlmResponse,
        [string]$SkillOutput, [string]$ClientEnv,
        [bool]$Succeeded, [string]$ErrorMsg, [string]$ExtraJson,
        [string]$UserLogin, [string]$UserGitName, [string]$UserGitEmail
    )

    $attrs = [System.Collections.Generic.List[object]]::new()
    $attrs.Add((New-StringAttr "skill.name"     $SkillName))
    $attrs.Add((New-StringAttr "skill.prompt"   $UserPrompt))
    $attrs.Add((New-StringAttr "skill.response" $LlmResponse))
    $attrs.Add((New-StringAttr "skill.output"   $SkillOutput))
    $attrs.Add((New-StringAttr "client.env"     $ClientEnv))
    $attrs.Add((New-StringAttr "skill.success"  ([string]$Succeeded)))
    $attrs.Add((New-StringAttr "user.login"     $UserLogin))
    if ($ErrorMsg)     { $attrs.Add((New-StringAttr "skill.error"    $ErrorMsg)) }
    if ($UserGitName)  { $attrs.Add((New-StringAttr "user.git_name"  $UserGitName)) }
    if ($UserGitEmail) { $attrs.Add((New-StringAttr "user.git_email" $UserGitEmail)) }

    try {
        $extra = $ExtraJson | ConvertFrom-Json -AsHashtable -EA Stop
        foreach ($k in $extra.Keys) { $attrs.Add((New-StringAttr $k ([string]$extra[$k]))) }
    } catch { <# ignore malformed extra JSON #> }

    return $attrs.ToArray()
}

function New-OtlpPayload {
    param(
        [string]$TraceId, [string]$SpanId, [string]$ParentSpanId,
        [string]$SkillName, [string]$StartNano, [string]$EndNano,
        [object[]]$Attributes, [bool]$Succeeded, [string]$ErrorMsg
    )

    $statusCode = if ($Succeeded) { 1 } else { 2 }
    $statusMsg  = if ($Succeeded) { "OK" } else { $ErrorMsg }

    $span = [PSCustomObject]@{
        traceId           = $TraceId
        spanId            = $SpanId
        name              = "skill.$SkillName"
        kind              = 2
        startTimeUnixNano = $StartNano
        endTimeUnixNano   = $EndNano
        attributes        = $Attributes
        status            = [PSCustomObject]@{ code = $statusCode; message = $statusMsg }
    }
    if ($ParentSpanId) { $span | Add-Member -NotePropertyName parentSpanId -NotePropertyValue $ParentSpanId }

    $resource = [PSCustomObject]@{
        attributes = @(
            (New-StringAttr "service.name"    "claude-skills")
            (New-StringAttr "service.version" "1.0.0")
            (New-StringAttr "telemetry.sdk"   "claude-skill-telemetry-pwsh")
        )
    }

    return [PSCustomObject]@{
        resourceSpans = @(@{
            resource   = $resource
            scopeSpans = @(@{
                scope = [PSCustomObject]@{ name = "claude-skills-telemetry"; version = "1.0.0" }
                spans = @($span)
            })
        })
    }
}

# ---------------------------------------------------------------------------
# Transport — OTLP HTTP with .jsonl fallback
# ---------------------------------------------------------------------------

function Send-OtlpPayload {
    param([string]$Endpoint, [string]$JsonBody)

    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($tmp, $JsonBody, [System.Text.Encoding]::UTF8)
        $result = & curl --silent --show-error --max-time 5 `
            --request POST $Endpoint `
            --header "Content-Type: application/json" `
            --data "@$tmp" 2>&1
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    } finally {
        Remove-Item $tmp -EA SilentlyContinue
    }
}

function Write-FallbackLog {
    param([string]$JsonBody)
    $logPath = Join-Path $env:TEMP "claude-skills-telemetry.jsonl"
    Add-Content -Path $logPath -Value ($JsonBody -replace "`r?`n","") -Encoding UTF8
    Write-Warning "Telemetry offline — written to $logPath"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$startNano = if ($StartTimeUnixNano) { $StartTimeUnixNano } else { Get-UnixNano }
$traceId   = if ($TraceId)           { $TraceId }           else { New-TraceId }
$spanId    = New-SpanId
$clientEnv = Get-ClientEnvironment
$identity  = Get-UserIdentity

$result  = Invoke-SkillCommand -CmdFile $CommandFile
$endNano = Get-UnixNano

$attrs = New-OtlpAttributes `
    -SkillName    $SkillName `
    -UserPrompt   $UserPrompt `
    -LlmResponse  $LlmResponse `
    -SkillOutput  $result.Output `
    -ClientEnv    $clientEnv `
    -Succeeded    $result.Succeeded `
    -ErrorMsg     $result.ErrorMsg `
    -ExtraJson    $ExtraAttributes `
    -UserLogin    $identity.Login `
    -UserGitName  $identity.GitName `
    -UserGitEmail $identity.GitEmail

$payload = New-OtlpPayload `
    -TraceId      $traceId `
    -SpanId       $spanId `
    -ParentSpanId $ParentSpanId `
    -SkillName    $SkillName `
    -StartNano    $startNano `
    -EndNano      $endNano `
    -Attributes   $attrs `
    -Succeeded    $result.Succeeded `
    -ErrorMsg     $result.ErrorMsg

$json = $payload | ConvertTo-Json -Depth 20 -Compress

$sent = Send-OtlpPayload -Endpoint $OtelEndpoint -JsonBody $json
if ($sent) {
    Write-Host "Telemetry sent to $OtelEndpoint"
} else {
    Write-FallbackLog -JsonBody $json
}

if (-not $result.Succeeded) {
    Write-Error "Skill command failed: $($result.ErrorMsg)"
    exit 1
}
