# codex-session.ps1 — Codex multi-account session manager
# Usage: codex-session [list|switch <email>|logout]

param(
    [string]$Command,
    [string]$Target
)

$ErrorActionPreference = "Stop"
$CodexAuth = "$env:USERPROFILE\.codex\auth.json"
$ProjectDir = $PSScriptRoot
$SessionsDir = Join-Path $ProjectDir "sessions"

function Decode-JwtPayload($token) {
    $parts = $token -split '\.'
    $payload = $parts[1] -replace '-', '+' -replace '_', '/'
    while ($payload.Length % 4 -ne 0) { $payload += '=' }
    $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))
    return $json | ConvertFrom-Json
}

function Get-AccountInfo($authPath) {
    $data = Get-Content $authPath -Raw | ConvertFrom-Json
    $jwt = Decode-JwtPayload $data.tokens.id_token
    $auth = $jwt.'https://api.openai.com/auth'
    $subStart = $auth.chatgpt_subscription_active_start
    $subUntil = $auth.chatgpt_subscription_active_until
    $refresh = if ($data.last_refresh -match '^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})') {
        "$($Matches[1]) $($Matches[2])"
    } else { $data.last_refresh }
    return [PSCustomObject]@{
        Email    = $jwt.email
        Name     = $jwt.name
        Plan     = $auth.chatgpt_plan_type
        Provider = $jwt.auth_provider
        UserId   = $auth.chatgpt_user_id
        AccountId= $data.tokens.account_id
        SubStart = if ($subStart) { ($subStart -split 'T')[0] } else { "?" }
        SubUntil = if ($subUntil) { ($subUntil -split 'T')[0] } else { "?" }
        Refresh  = $refresh
        Path     = $authPath
    }
}

function Get-CurrentAccount {
    if (Test-Path $CodexAuth) { return Get-AccountInfo $CodexAuth }
    return $null
}

function Get-SavedAccounts {
    $accounts = @()
    if (Test-Path $SessionsDir) {
        foreach ($dir in Get-ChildItem $SessionsDir -Directory -ErrorAction SilentlyContinue) {
            $authFile = Join-Path $dir.FullName "auth.json"
            if (Test-Path $authFile) { $accounts += Get-AccountInfo $authFile }
        }
    }
    return $accounts | Sort-Object Email
}

function Save-Current {
    if (-not (Test-Path $CodexAuth)) { return $null }
    $info = Get-AccountInfo $CodexAuth
    $targetDir = Join-Path $SessionsDir $info.Email
    New-Item -ItemType Directory -Force $targetDir | Out-Null
    Copy-Item $CodexAuth (Join-Path $targetDir "auth.json") -Force
    return $info
}

function Write-Table($rows, $columns) {
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

function Invoke-List {
    Save-Current | Out-Null
    $current = Get-CurrentAccount
    $accounts = Get-SavedAccounts
    if ($accounts.Count -eq 0) {
        Write-Output "No saved accounts."
        return
    }

    $curEmail = if ($current) { $current.Email } else { "" }
    $rows = @()
    foreach ($a in $accounts) {
        $uidShort = $a.UserId
        if ($uidShort.Length -gt 28) { $uidShort = $uidShort.Substring(0, 14) + "..." + $uidShort.Substring($uidShort.Length - 14) }
        $aidShort = $a.AccountId.Substring(0, 8) + "..." + $a.AccountId.Substring($a.AccountId.Length - 4)
        $rows += [PSCustomObject]@{
            A        = if ($a.Email -eq $curEmail) { "*" } else { "" }
            Email    = $a.Email
            Name     = $a.Name
            Plan     = $a.Plan
            Provider = $a.Provider
            UserId   = $uidShort
            AcctId   = $aidShort
            Sub      = "$($a.SubStart) ~ $($a.SubUntil)"
            Refresh  = $a.Refresh
        }
    }

    Write-Output ""
    Write-Table $rows @("A", "Email", "Name", "Plan", "Provider", "UserId", "AcctId", "Sub", "Refresh")
    Write-Output ""
}

function Invoke-Switch($email) {
    Save-Current | Out-Null
    $accounts = Get-SavedAccounts
    $match = $accounts | Where-Object { $_.Email -eq $email }

    if (-not $match) {
        $matches = $accounts | Where-Object { $_.Email -like "*$email*" }
        if ($matches.Count -eq 1) {
            $match = $matches[0]
        } elseif ($matches.Count -gt 1) {
            Write-Output "Multiple matches:"
            $matches | ForEach-Object { Write-Output "  $($_.Email)" }
            exit 1
        } else {
            Write-Output "No account matching '$email'. Run 'codex-session' to see saved accounts."
            exit 1
        }
    }

    Copy-Item $match.Path $CodexAuth -Force
    Write-Output "Switched to: $($match.Email) ($($match.Plan))"
}

function Invoke-Logout {
    Save-Current | Out-Null
    if (Test-Path $CodexAuth) {
        $info = Get-CurrentAccount
        Remove-Item $CodexAuth -Force
        Write-Output "Logged out: $($info.Email)"
    }
    Write-Output "Log in with a new account, then run: codex-session"
}

function Invoke-Interactive {
    $saved = Save-Current
    if ($saved) { Write-Output "Synced: $($saved.Email)" }

    $current = Get-CurrentAccount
    $accounts = Get-SavedAccounts
    if ($accounts.Count -eq 0) {
        Write-Output "`nNo other accounts. Log in with a different account and run 'codex-session' again."
        return
    }

    Write-Output ""
    for ($i = 0; $i -lt $accounts.Count; $i++) {
        $a = $accounts[$i]
        $marker = if ($current -and $a.Email -eq $current.Email) { "*" } else { " " }
        Write-Output "  [$i] $marker $($a.Email)"
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
                    Invoke-Switch $accounts[$idx].Email
                } else { Write-Output "Invalid index." }
            } else { Write-Output "Invalid choice." }
        }
    }
}

# Main
if (-not $Command) {
    Invoke-Interactive
} else {
    switch ($Command) {
        'list'   { Invoke-List }
        'switch' {
            if (-not $Target) {
                Write-Output "Usage: codex-session switch <email>"
                exit 1
            }
            Invoke-Switch $Target
        }
        'logout' { Invoke-Logout }
        default  {
            Write-Output "Unknown command: $Command"
            Write-Output "Usage: codex-session [list|switch <email>|logout]"
            exit 1
        }
    }
}
