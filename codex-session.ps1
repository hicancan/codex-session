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

function Get-OrgProperty($authClaim, $propName) {
    if (-not $authClaim.organizations) { return "?" }
    $orgs = $authClaim.organizations
    if ($orgs -is [array]) { return $orgs[0].$propName }
    return $orgs.$propName
}

function Get-AccountInfo($authPath) {
    try {
        $data = [System.IO.File]::ReadAllText($authPath) | ConvertFrom-Json
        $jwt = Decode-JwtPayload $data.tokens.id_token
        $auth = $jwt.'https://api.openai.com/auth'
        $subStart = $auth.chatgpt_subscription_active_start
        $subUntil = $auth.chatgpt_subscription_active_until
        
        # Robust date parsing (handles both "YYYY-MM-DDTHH:MM..." and "MM/DD/YYYY HH:MM...")
        $parseDate = {
            param($d)
            if (-not $d) { return "?" }
            if ($d -match '^(\d{4}-\d{2}-\d{2}|\d{2}/\d{2}/\d{4})') { return $Matches[1] }
            return ($d -split ' ')[0]
        }
        
        $refresh = if ($data.last_refresh -match '^(\d{4}-\d{2}-\d{2}|\d{2}/\d{2}/\d{4})[T\s](\d{2}:\d{2})') {
            "$($Matches[1]) $($Matches[2])"
        } else { $data.last_refresh }

        return [PSCustomObject]@{
            Email     = $jwt.email
            Name      = $jwt.name
            Plan      = $auth.chatgpt_plan_type
            Provider  = $jwt.auth_provider
            UserId    = $auth.chatgpt_user_id
            AccountId = $data.tokens.account_id
            OrgId     = Get-OrgProperty $auth "id"
            OrgTitle  = Get-OrgProperty $auth "title"
            SubStart  = &$parseDate $subStart
            SubUntil  = &$parseDate $subUntil
            Refresh   = $refresh
            Path      = $authPath
        }
    } catch {
        throw "[Fatal Error] State synchronization failed: Unable to parse JSON sequence at ($authPath). Details: $($_.Exception.Message)"
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
    if (-not (Test-Path $SessionsDir)) { return @() }

    $accounts = foreach ($emailDir in Get-ChildItem $SessionsDir -Directory -ErrorAction SilentlyContinue) {
        foreach ($acctDir in Get-ChildItem $emailDir.FullName -Directory -ErrorAction SilentlyContinue) {
            $authFile = Join-Path $acctDir.FullName "auth.json"
            if (Test-Path $authFile) {
                Get-AccountInfo $authFile
            }
        }
    }
    return $accounts | Sort-Object AccountId, Email
}

# ============================================================================
# Save & Switch
# ============================================================================

function Save-Current {
    if (-not (Test-Path $CodexAuth)) { return $null }
    
    Invoke-WithLock "Local\CodexSessionMutex" 15000 {
        $info = Get-AccountInfo $CodexAuth
        $acctId = if ($info.AccountId) { $info.AccountId } else { "_unknown" }
        $safeEmail = $info.Email -replace '[\\/:\*\?"<>\|]', '_'
        $safeAcctId = $acctId -replace '[\\/:\*\?"<>\|]', '_'
        $targetDir = Join-Path $SessionsDir (Join-Path $safeEmail $safeAcctId)
        New-Item -ItemType Directory -Force $targetDir | Out-Null
        
        $tmpFile = Join-Path $targetDir "auth.tmp.json"
        Copy-Item $CodexAuth $tmpFile -Force
        Move-Item $tmpFile (Join-Path $targetDir "auth.json") -Force
        
        return $info
    }
}

# ============================================================================
# Table Rendering
# ============================================================================

function Write-Table($rows, $columns) {
    if ($rows.Count -eq 0) { return }
    $widths = @{}
    foreach ($col in $columns) { $widths[$col] = $col.Length }
    
    $processedRows = @()
    foreach ($row in $rows) {
        $pRow = @{}
        foreach ($col in $columns) {
            $val = if ($row.$col) { $row.$col.ToString() } else { "" }
            # Truncate long UUIDs for cleaner display
            if ($col -in @("UserId", "AcctId", "OrgId") -and $val.Length -gt 8) {
                $val = $val.Substring(0, 8) + ".."
            }
            $pRow[$col] = $val
            if ($val.Length -gt $widths[$col]) { $widths[$col] = $val.Length }
        }
        $processedRows += $pRow
    }
    
    $esc = [char]27
    $header = ""; $sep = ""
    foreach ($col in $columns) {
        $displayName = if ($col -eq "A") { " " } else { $col }
        $header += "$esc[38;5;14m" + $displayName.PadRight($widths[$col] + 2) + "$esc[0m"
        $sep += "$esc[38;5;238m" + ("-" * $widths[$col]) + "  $esc[0m"
    }
    Write-Output "  $header"
    Write-Output "  $sep"
    
    foreach ($row in $processedRows) {
        $line = ""
        $isActive = ($row["A"].Trim() -eq "*")
        
        foreach ($col in $columns) {
            $val = $row[$col].PadRight($widths[$col] + 2)
            
            if ($isActive) {
                $val = "$esc[38;5;48m" + $val + "$esc[0m" # Neon Green for active row
            } elseif ($col -eq "A") {
                $val = "$esc[38;5;240m" + $val + "$esc[0m"
            } elseif ($col -in @("UserId", "AcctId", "OrgId", "Sub", "Refresh", "Provider")) {
                $val = "$esc[38;5;244m" + $val + "$esc[0m" # Soft Gray for metadata
            } elseif ($col -eq "Plan") {
                if ($row[$col] -like "*business*") {
                    $val = "$esc[38;5;205m" + $val + "$esc[0m" # Pink/Magenta for business
                } else {
                    $val = "$esc[38;5;220m" + $val + "$esc[0m" # Gold for team
                }
            } else {
                $val = "$esc[38;5;253m" + $val + "$esc[0m" # Bright White for main text
            }
            $line += $val
        }
        Write-Output "  $line"
    }
}

function Write-CardList {
    param([array]$Rows)
    $esc = [char]27
    
    foreach ($row in $Rows) {
        $isActive = ($row.A.Trim() -eq "*")
        $mainColor = if ($isActive) { "$esc[38;5;48m" } else { "$esc[38;5;253m" }
        $lblColor = "$esc[38;5;244m"
        $valColor = "$esc[38;5;253m"
        $planColor = if ($row.Plan -like "*business*") { "$esc[38;5;205m" } else { "$esc[38;5;220m" }
        
        $marker = if ($isActive) { "$esc[38;5;48m* $esc[0m" } else { "  " }
        
        Write-Output "  $esc[38;5;238m----------------------------------------------------------------------$esc[0m"
        Write-Output "  $marker$mainColor$($row.Email)$esc[0m $lblColor($($row.AcctId))$esc[0m"
        Write-Output "    $lblColor$('Name'.PadRight(10)):$esc[0m $valColor$($row.Name)$esc[0m"
        Write-Output "    $lblColor$('Plan'.PadRight(10)):$esc[0m $planColor$($row.Plan)$esc[0m"
        Write-Output "    $lblColor$('Provider'.PadRight(10)):$esc[0m $valColor$($row.Provider)$esc[0m"
        Write-Output "    $lblColor$('UserId'.PadRight(10)):$esc[0m $valColor$($row.UserId)$esc[0m"
        Write-Output "    $lblColor$('OrgId'.PadRight(10)):$esc[0m $valColor$($row.OrgId)  $lblColor(Title: $($row.OrgTitle))$esc[0m"
        Write-Output "    $lblColor$('Sub'.PadRight(10)):$esc[0m $valColor$($row.Sub)$esc[0m"
        Write-Output "    $lblColor$('Refresh'.PadRight(10)):$esc[0m $valColor$($row.Refresh)$esc[0m"
    }
    Write-Output "  $esc[38;5;238m----------------------------------------------------------------------$esc[0m"
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
    $rows = foreach ($a in $accounts) {
        [PSCustomObject]@{
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
    
    # Responsive CLI Design: If the terminal is narrower than 150 columns, the table will wrap and look terrible.
    # Fallback to the elegant Card View.
    if ($Host.UI.RawUI.WindowSize.Width -lt 150) {
        Write-CardList $rows
    } else {
        Write-Table $rows @("A", "Email", "Name", "Plan", "Provider", "UserId", "AcctId", "OrgId", "OrgTitle", "Sub", "Refresh")
    }
    
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

    # Pre-flight check: Can we write to the target CodexAuth file?
    try {
        $testStream = [System.IO.File]::OpenWrite($CodexAuth)
        $testStream.Close()
    } catch {
        throw "[Fatal Error] Pre-flight check failed: Cannot write to $CodexAuth."
    }

    Invoke-WithLock "Local\CodexSessionMutex" 15000 {
        $tmpFile = "$CodexAuth.tmp"
        Copy-Item $targetAccount.Path $tmpFile -Force
        Move-Item $tmpFile $CodexAuth -Force
    }

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

    # Determine if any email has multiple sessions to disambiguate
    $needsPlanCol = $false
    $emailCounts = @{}
    foreach ($a in $accounts) {
        if (-not $emailCounts.ContainsKey($a.Email)) { $emailCounts[$a.Email] = 0 }
        $emailCounts[$a.Email]++
        if ($emailCounts[$a.Email] -gt 1) { $needsPlanCol = $true }
    }

    $esc = [char]27
    Write-Output ""
    
    $maxEmailLen = 0
    $maxPlanLen = 0
    foreach ($a in $accounts) {
        if ($a.Email.Length -gt $maxEmailLen) { $maxEmailLen = $a.Email.Length }
        if ($a.Plan.Length -gt $maxPlanLen) { $maxPlanLen = $a.Plan.Length }
    }

    $lastTeam = ""
    for ($i = 0; $i -lt $accounts.Count; $i++) {
        $a = $accounts[$i]
        
        # Add visual separator between different teams
        if ($lastTeam -ne "" -and $lastTeam -ne $a.AccountId) {
            Write-Output "  $esc[38;5;238m----------------------------------------------------------------------$esc[0m"
        }
        $lastTeam = $a.AccountId
        
        $isActive = ("$($a.Email)|$($a.AccountId)" -eq $curKey)
        $marker = if ($isActive) { "$esc[38;5;48m* " } else { "  " }
        
        $idxStr = "[$i]".PadRight(4)
        
        # Colorize Plan
        $planColor = if ($a.Plan -like "*business*") { "$esc[38;5;205m" } else { "$esc[38;5;220m" }
        
        $extra = ""
        if ($needsPlanCol) {
            $shortId = if ($a.AccountId) { $a.AccountId.Substring(0, [math]::Min(8, $a.AccountId.Length)) } else { "?" }
            # Use EXACT raw string without smart recognition, but pad for alignment
            $extra = "  $planColor$($a.Plan.PadRight($maxPlanLen))$esc[0m  $esc[38;5;244m($shortId)$esc[0m"
        }
        
        $paddedEmail = $a.Email.PadRight($maxEmailLen)
        
        if ($isActive) {
            Write-Output "  $esc[38;5;240m$idxStr$esc[0m $marker$esc[38;5;48m$paddedEmail$esc[0m$extra"
        } else {
            Write-Output "  $esc[38;5;240m$idxStr$esc[0m $marker$esc[38;5;253m$paddedEmail$esc[0m$extra"
        }
    }

    Write-Output "`n  $esc[38;5;14m[l]$esc[0m Full detail table"
    Write-Output "  $esc[38;5;14m[d]$esc[0m Logout (for new login)"
    Write-Output "  $esc[38;5;14m[q]$esc[0m Quit$esc[0m"
    $choice = Read-Host "`n$esc[38;5;14m>$esc[0m"

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
# Concurrency Management
# ============================================================================

function Invoke-WithLock([string]$MutexName, [int]$TimeoutMs, [scriptblock]$Action) {
    $mutex = $null
    $lockAcquired = $false
    $createdNew = $false
    try {
        $mutex = [System.Threading.Mutex]::new($false, $MutexName, [ref]$createdNew)
        $lockAcquired = $mutex.WaitOne($TimeoutMs)
        if (-not $lockAcquired) { throw "[Fatal Error] Failed to acquire lock '$MutexName' within timeout." }
        return & $Action
    } finally {
        if ($lockAcquired) { $mutex.ReleaseMutex() }
        if ($mutex) { $mutex.Dispose() }
    }
}

# ============================================================================
# Auth Parsing
# ============================================================================

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
