# codex-session.ps1 — Codex multi-account session manager
# Usage: codex-session [list|switch <matcher>|logout]
#
# Directory structure:
#   sessions/<email>/<account_id>/auth.json
#   - email:     JWT email claim (human-readable grouping key)
#   - account_id: tokens.account_id (globally unique session key, full UUID)

param(
    [string]$Command,
    [string]$Target
)

$ErrorActionPreference = "Stop"
$CodexAuth = "$env:USERPROFILE\.codex\auth.json"
$ProjectDir = $PSScriptRoot
$SessionsDir = Join-Path $ProjectDir "sessions"

# ============================================================================
# JWT & Account Info
# ============================================================================

function Decode-JwtPayload($token) {
    $parts = $token -split '\.'
    if ($parts.Count -lt 3) { return $null }
    $payload = $parts[1] -replace '-', '+' -replace '_', '/'
    while ($payload.Length % 4 -ne 0) { $payload += '=' }
    try {
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))
        return $json | ConvertFrom-Json
    } catch { return $null }
}

function Get-OrgId($authClaim) {
    if (-not $authClaim.organizations) { return "?" }
    $orgs = $authClaim.organizations
    if ($orgs -is [array]) { return $orgs[0].id }
    return $orgs.id
}

function Get-OrgTitle($authClaim) {
    if (-not $authClaim.organizations) { return "?" }
    $orgs = $authClaim.organizations
    if ($orgs -is [array]) { return $orgs[0].title }
    return $orgs.title
}

function Get-AccountInfo($authPath) {
    try {
        $data = Get-Content $authPath -Raw | ConvertFrom-Json
        $jwt = Decode-JwtPayload $data.tokens.id_token
        $auth = $jwt.'https://api.openai.com/auth'
        $subStart = $auth.chatgpt_subscription_active_start
        $subUntil = $auth.chatgpt_subscription_active_until
        $refresh = if ($data.last_refresh -match '^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})') {
            "$($Matches[1]) $($Matches[2])"
        } else { $data.last_refresh }
        return [PSCustomObject]@{
            Email     = $jwt.email
            Name      = $jwt.name
            Plan      = $auth.chatgpt_plan_type
            Provider  = $jwt.auth_provider
            UserId    = $auth.chatgpt_user_id
            AccountId = $data.tokens.account_id
            OrgId     = Get-OrgId $auth
            OrgTitle  = Get-OrgTitle $auth
            SubStart  = if ($subStart) { ($subStart -split 'T')[0] } else { "?" }
            SubUntil  = if ($subUntil) { ($subUntil -split 'T')[0] } else { "?" }
            Refresh   = $refresh
            Path      = $authPath
        }
    } catch {
        return $null
    }
}

# ============================================================================
# Session Scanning & Migration
# ============================================================================

function Get-CurrentAccount {
    if (Test-Path $CodexAuth) { return Get-AccountInfo $CodexAuth }
    return $null
}

function Get-SavedAccounts {
    $accounts = @()
    if (-not (Test-Path $SessionsDir)) { return $accounts }

    foreach ($emailDir in Get-ChildItem $SessionsDir -Directory -ErrorAction SilentlyContinue) {
        foreach ($acctDir in Get-ChildItem $emailDir.FullName -Directory -ErrorAction SilentlyContinue) {
            $authFile = Join-Path $acctDir.FullName "auth.json"
            if (Test-Path $authFile) {
                try { $accounts += Get-AccountInfo $authFile } catch {}
            }
        }
    }
    return $accounts | Sort-Object Email, AccountId
}

# ============================================================================
# Save & Switch
# ============================================================================

function Save-Current {
    if (-not (Test-Path $CodexAuth)) { return $null }
    $info = Get-AccountInfo $CodexAuth
    $acctId = if ($info.AccountId) { $info.AccountId } else { "_unknown" }
    $safeEmail = $info.Email -replace '[\\/:\*\?"<>\|]', '_'
    $safeAcctId = $acctId -replace '[\\/:\*\?"<>\|]', '_'
    $targetDir = Join-Path $SessionsDir (Join-Path $safeEmail $safeAcctId)
    New-Item -ItemType Directory -Force $targetDir | Out-Null
    Copy-Item $CodexAuth (Join-Path $targetDir "auth.json") -Force
    return $info
}

# ============================================================================
# Table Rendering
# ============================================================================

function Write-Table($rows, $columns) {
    if ($rows.Count -eq 0) { return }
    $widths = @{}
    foreach ($col in $columns) { $widths[$col] = $col.Length }
    foreach ($row in $rows) {
        foreach ($col in $columns) {
            $val = if ($row.$col) { $row.$col.ToString() } else { "" }
            if ($val.Length -gt $widths[$col]) { $widths[$col] = $val.Length }
        }
    }
    $header = ""; $sep = ""
    foreach ($col in $columns) {
        $header += $col.PadRight($widths[$col] + 2)
        $sep += ("-" * $widths[$col]) + "  "
    }
    Write-Output $header
    Write-Output $sep
    foreach ($row in $rows) {
        $line = ""
        foreach ($col in $columns) {
            $val = if ($row.$col) { $row.$col.ToString() } else { "" }
            $line += $val.PadRight($widths[$col] + 2)
        }
        Write-Output $line
    }
}

# ============================================================================
# Commands
# ============================================================================

function Invoke-List {
    $current = Save-Current
    $accounts = Get-SavedAccounts
    if ($accounts.Count -eq 0) {
        Write-Output "No saved accounts."
        return
    }

    $curKey = if ($current) { "$($current.Email)|$($current.AccountId)" } else { "" }
    $rows = @()
    foreach ($a in $accounts) {
        $rows += [PSCustomObject]@{
            A        = if ("$($a.Email)|$($a.AccountId)" -eq $curKey) { "*" } else { "" }
            Email    = $a.Email
            Name     = $a.Name
            Plan     = $a.Plan
            Provider = $a.Provider
            UserId   = $a.UserId
            AcctId   = $a.AccountId
            OrgId    = $a.OrgId
            OrgTitle = $a.OrgTitle
            Sub      = "$($a.SubStart) ~ $($a.SubUntil)"
            Refresh  = $a.Refresh
        }
    }

    Write-Output ""
    Write-Table $rows @("A", "Email", "Name", "Plan", "Provider", "UserId", "AcctId", "OrgId", "OrgTitle", "Sub", "Refresh")
    Write-Output ""
}

function Invoke-Switch($matcher) {
    $current = Save-Current
    $accounts = Get-SavedAccounts

    if ($accounts.Count -eq 0) {
        Write-Output "No saved accounts. Run 'codex-session' after logging in."
        exit 1
    }

    $targetAccount = $null

    # Match strategy: email:sub (plan or account_id prefix)
    if ($matcher -match '^(.+):(.+)$') {
        $emailPart = $Matches[1]
        $subPart = $Matches[2]
        $emailMatches = @($accounts | Where-Object { $_.Email -eq $emailPart })
        if ($emailMatches.Count -eq 0) {
            Write-Output "No account with email '$emailPart'."
            exit 1
        }
        # Try sub-match by plan_type (case-insensitive)
        $planMatch = @($emailMatches | Where-Object { $_.Plan -eq $subPart })
        if ($planMatch.Count -eq 1) {
            $targetAccount = $planMatch[0]
        } elseif ($planMatch.Count -gt 1) {
            Write-Output "Multiple sessions match '$matcher':"
            $planMatch | ForEach-Object { Write-Output "  $($_.Email)  $($_.Plan)  $($_.AccountId)" }
            exit 1
        }
        # Try sub-match by account_id prefix
        if (-not $targetAccount) {
            $acctMatches = @($emailMatches | Where-Object { $_.AccountId.StartsWith($subPart) })
            if ($acctMatches.Count -eq 1) {
                $targetAccount = $acctMatches[0]
            } elseif ($acctMatches.Count -gt 1) {
                Write-Output "Multiple sessions match '$matcher':"
                $acctMatches | ForEach-Object { Write-Output "  $($_.Email)  $($_.Plan)  $($_.AccountId)" }
                exit 1
            } else {
                Write-Output "No session matching '$subPart' under '$emailPart'."
                Write-Output "Available:"
                $emailMatches | ForEach-Object { Write-Output "  $($_.Email)  $($_.Plan)  $($_.AccountId)" }
                exit 1
            }
        }
    }

    # Match by exact email
    if (-not $targetAccount) {
        $emailExact = @($accounts | Where-Object { $_.Email -eq $matcher })
        if ($emailExact.Count -eq 1) {
            $targetAccount = $emailExact[0]
        } elseif ($emailExact.Count -gt 1) {
            Write-Output "Multiple sessions for $matcher`:"
            for ($i = 0; $i -lt $emailExact.Count; $i++) {
                Write-Output "  [$i] $($emailExact[$i].Plan)  ($($emailExact[$i].AccountId))"
            }
            Write-Output "Use: codex-session switch ${matcher}:<plan>"
            Write-Output "  or: codex-session switch ${matcher}:<account_id_prefix>"
            exit 1
        }
    }

    # Match by account_id prefix (global search)
    if (-not $targetAccount) {
        $acctGlobal = @($accounts | Where-Object { $_.AccountId.StartsWith($matcher) })
        if ($acctGlobal.Count -eq 1) {
            $targetAccount = $acctGlobal[0]
        } elseif ($acctGlobal.Count -gt 1) {
            Write-Output "Multiple sessions match account_id prefix '$matcher':"
            $acctGlobal | ForEach-Object { Write-Output "  $($_.Email)  $($_.Plan)  $($_.AccountId)" }
            exit 1
        }
    }

    # Match by fuzzy email
    if (-not $targetAccount) {
        $escaped = [WildcardPattern]::Escape($matcher)
        $emailFuzzy = @($accounts | Where-Object { $_.Email -like "*$escaped*" })
        if ($emailFuzzy.Count -eq 1) {
            $targetAccount = $emailFuzzy[0]
        } elseif ($emailFuzzy.Count -gt 1) {
            # Check if all matches are the same email (different account_ids)
            $distinctEmails = @($emailFuzzy | Select-Object -ExpandProperty Email -Unique)
            if ($distinctEmails.Count -eq 1) {
                Write-Output "Multiple sessions for $($distinctEmails[0]):"
                for ($i = 0; $i -lt $emailFuzzy.Count; $i++) {
                    Write-Output "  [$i] $($emailFuzzy[$i].Plan)  ($($emailFuzzy[$i].AccountId))"
                }
                Write-Output "Use: codex-session switch $($distinctEmails[0]):<plan>"
                Write-Output "  or: codex-session switch $($distinctEmails[0]):<account_id_prefix>"
            } else {
                Write-Output "Multiple emails match '$matcher':"
                $emailFuzzy | ForEach-Object { Write-Output "  $($_.Email)  $($_.Plan)" }
            }
            exit 1
        }
    }

    if (-not $targetAccount) {
        Write-Output "No account matching '$matcher'. Run 'codex-session' to see saved accounts."
        exit 1
    }

    # ---- INJECT DYNAMIC SEAT SCHEDULER ----
    Write-Host ">>> [Dynamic Seat Manager] Checking and allocating ChatGPT seat for $($targetAccount.Email)..." -ForegroundColor Cyan
    $nodeScript = Join-Path $ProjectDir "seat-manager.js"
    if (Test-Path $nodeScript) {
        try {
            $seatResult = & node $nodeScript "$($targetAccount.Email)" 2>&1
            Write-Host $seatResult -ForegroundColor Yellow
            if ($LASTEXITCODE -ne 0) {
                Write-Host "[!] Seat drift failed (Cloudflare or Chrome disconnected). Aborting local switch to maintain consistency." -ForegroundColor Red
                exit 1
            }
        } catch {
            Write-Host "[!] Failed to execute seat-manager script. Aborting." -ForegroundColor Red
            exit 1
        }
    }
    # ---------------------------------------

    Copy-Item $targetAccount.Path $CodexAuth -Force
    Write-Output "Switched to: $($targetAccount.Email)  [$($targetAccount.Plan)]  ($($targetAccount.AccountId))"
}

function Invoke-Logout {
    $info = Save-Current
    if (Test-Path $CodexAuth) {
        Remove-Item $CodexAuth -Force
        Write-Output "Logged out: $($info.Email)  [$($info.Plan)]"
    }
    Write-Output "Log in with a new account, then run: codex-session"
}

function Invoke-Interactive {
    $current = Save-Current
    if ($current) { Write-Output "Synced: $($current.Email) [$($current.Plan)]" }

    $accounts = Get-SavedAccounts
    if ($accounts.Count -eq 0) {
        Write-Output "`nNo saved accounts. Log in with a different account and run 'codex-session' again."
        return
    }

    $curKey = if ($current) { "$($current.Email)|$($current.AccountId)" } else { "" }

    # Determine if any email has multiple sessions (need plan column to disambiguate)
    $needsPlanCol = $false
    $emailCounts = @{}
    foreach ($a in $accounts) {
        if (-not $emailCounts.ContainsKey($a.Email)) { $emailCounts[$a.Email] = 0 }
        $emailCounts[$a.Email]++
        if ($emailCounts[$a.Email] -gt 1) { $needsPlanCol = $true }
    }

    Write-Output ""
    for ($i = 0; $i -lt $accounts.Count; $i++) {
        $a = $accounts[$i]
        $marker = if ("$($a.Email)|$($a.AccountId)" -eq $curKey) { "*" } else { " " }
        $extra = if ($needsPlanCol) { "  $($a.Plan)" } else { "" }
        Write-Output "  [$i] $marker $($a.Email)$extra"
    }

    Write-Output "`n  [l] Full detail table"
    Write-Output "  [d] Logout (for new login)"
    Write-Output "  [q] Quit"
    $choice = Read-Host "`n>"

    switch ($choice) {
        'q' { return }
        'l' { Invoke-List }
        'd' { Invoke-Logout }
        default {
            if ($choice -match '^\d+$') {
                $idx = [int]$choice
                if ($idx -ge 0 -and $idx -lt $accounts.Count) {
                    Invoke-Switch "$($accounts[$idx].Email):$($accounts[$idx].AccountId)"
                } else { Write-Output "Invalid index." }
            } else { Write-Output "Invalid choice." }
        }
    }
}

# ============================================================================
# Main
# ============================================================================

if (-not $Command) {
    Invoke-Interactive
} else {
    switch ($Command) {
        'list'   { Invoke-List }
        'switch' {
            if (-not $Target) {
                Write-Output "Usage: codex-session switch <email|email:plan|email:account_id|account_id>"
                exit 1
            }
            Invoke-Switch $Target
        }
        'logout' { Invoke-Logout }
        default  {
            Write-Output "Unknown command: $Command"
            Write-Output "Usage: codex-session [list|switch <matcher>|logout]"
            exit 1
        }
    }
}
