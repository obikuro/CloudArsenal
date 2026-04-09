#Requires -Version 5.1
<#
.SYNOPSIS
    AzEnum - Azure Resource & Permissions Enumerator 

.DESCRIPTION
    Enumerates all accessible subscriptions, resources within each subscription,
    and effective permissions (actions / notActions / dataActions) per resource.
    

.NOTES
    Author  : Edrian
    Module  : AzEnum
    Version : 2.1.0
    Usage   : Import-Module .\AzEnum.ps1
              Enumerate-AzResources -Token "eyJ0eXAi..."
              Enumerate-AzResources -Token "eyJ0eXAi..." -ExportJson ".\results.json" -ThrottleMs 400
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─────────────────────────────────────────────────────────────────────────────
#  PRIVATE — DISPLAY HELPERS
# ─────────────────────────────────────────────────────────────────────────────

function Write-Banner {
    param(
        [string]$Tool     = "AzEnum",
        [string]$Operator = "Edrian"
    )

    # Palette from your image
    $Primary = @{ R = 206; G = 145; B = 120 }   # #CE9178
    $Accent  = @{ R = 166; G = 113; B =  91 }   # darker accent
    $Muted   = @{ R = 120; G = 120; B = 120 }   # neutral gray

    function Write-RGB {
        param(
            [string]$Text,
            [int]$R,
            [int]$G,
            [int]$B,
            [switch]$NoNewline
        )

        $esc = [char]27
        $ansiText = "$esc[38;2;${R};${G};${B}m$Text$esc[0m"

        if ($NoNewline) {
            Write-Host $ansiText -NoNewline
        }
        else {
            Write-Host $ansiText
        }
    }

    function Write-RGBLine {
        param(
            [string]$Left,
            [string]$Value,
            [hashtable]$LeftColor,
            [hashtable]$ValueColor,
            [int]$Width = 74
        )

        $plain = "$Left$Value"
        $pad = $Width - $plain.Length
        if ($pad -lt 0) { $pad = 0 }

        Write-RGB "   │ " $Accent.R $Accent.G $Accent.B -NoNewline
        Write-RGB $Left  $LeftColor.R  $LeftColor.G  $LeftColor.B -NoNewline
        Write-RGB $Value $ValueColor.R $ValueColor.G $ValueColor.B -NoNewline
        Write-RGB (" " * $pad) $ValueColor.R $ValueColor.G $ValueColor.B -NoNewline
        Write-RGB " │" $Accent.R $Accent.G $Accent.B
    }

    Write-Host ""

    Write-RGB "    ██████╗██╗      ██████╗ ██╗   ██╗██████╗  █████╗ ██████╗ ███████╗███████╗███╗   ██╗ █████╗ ██╗     " $Accent.R $Accent.G $Accent.B
    Write-RGB "   ██╔════╝██║     ██╔═══██╗██║   ██║██╔══██╗██╔══██╗██╔══██╗██╔════╝██╔════╝████╗  ██║██╔══██╗██║     " $Primary.R $Primary.G $Primary.B
    Write-RGB "   ██║     ██║     ██║   ██║██║   ██║██║  ██║███████║██████╔╝███████╗█████╗  ██╔██╗ ██║███████║██║     " $Primary.R $Primary.G $Primary.B
    Write-RGB "   ██║     ██║     ██║   ██║██║   ██║██║  ██║██╔══██║██╔══██╗╚════██║██╔══╝  ██║╚██╗██║██╔══██║██║     " $Primary.R $Primary.G $Primary.B
    Write-RGB "   ╚██████╗███████╗╚██████╔╝╚██████╔╝██████╔╝██║  ██║██║  ██║███████║███████╗██║ ╚████║██║  ██║███████╗" $Accent.R $Accent.G $Accent.B
    Write-RGB "    ╚═════╝╚══════╝ ╚═════╝  ╚═════╝ ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚══════╝╚═╝  ╚═══╝╚═╝  ╚═╝╚══════╝" $Primary.R $Primary.G $Primary.B

    Write-Host ""

    Write-RGB "   ┌──────────────────────────────────────────────────────────────────────────┐" $Accent.R $Accent.G $Accent.B
    Write-RGBLine " [ TOOL     ] "  $Tool     $Muted   $Primary
    Write-RGBLine " [ OPERATOR ] "  $Operator $Muted   $Primary
    Write-RGBLine " [ MODULE   ] " "Cloud Enumeration" $Muted $Primary
    Write-RGB "   └──────────────────────────────────────────────────────────────────────────┘" $Accent.R $Accent.G $Accent.B

    Write-Host ""
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "  ┌──────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host "  │  $Title" -ForegroundColor Yellow
    Write-Host "  └──────────────────────────────────────────────" -ForegroundColor DarkGray
}

function Write-Good { param([string]$Msg) Write-Host "  [+] $Msg" -ForegroundColor Green  }
function Write-Info { param([string]$Msg) Write-Host "  [*] $Msg" -ForegroundColor Cyan   }
function Write-Warn { param([string]$Msg) Write-Host "  [!] $Msg" -ForegroundColor Yellow }
function Write-Bad  { param([string]$Msg) Write-Host "  [-] $Msg" -ForegroundColor Red    }

# ─────────────────────────────────────────────────────────────────────────────
#  PRIVATE — NETWORK HELPERS
# ─────────────────────────────────────────────────────────────────────────────

function Get-AuthHeaders {
    param([string]$BearerToken)
    return @{
        "Authorization" = "Bearer $BearerToken"
        "Content-Type"  = "application/json"
    }
}

# Invoke-RestMethod wrapper with 429 retry and graceful error handling.
# Returns $null on access denied / not found so callers can skip cleanly.
function Invoke-AzRestMethod {
    param(
        [string]   $Uri,
        [hashtable]$Headers,
        [int]      $MaxRetries = 3
    )
    $attempt = 0
    while ($attempt -lt $MaxRetries) {
        try {
            return Invoke-RestMethod -Method Get -Uri $Uri -Headers $Headers -ErrorAction Stop
        }
        catch {
            $code = $null
            try { $code = [int]$_.Exception.Response.StatusCode } catch {}

            if ($code -eq 429) {
                $wait = 10
                try { $wait = [int]$_.Exception.Response.Headers["Retry-After"] } catch {}
                Write-Warn "Rate-limited (429) — waiting ${wait}s..."
                Start-Sleep -Seconds $wait
                $attempt++
            }
            elseif ($code -in @(401, 403)) {
                Write-Warn "Access denied ($code): $Uri"
                return $null
            }
            elseif ($code -eq 404) {
                return $null   # permissions endpoint absent — silently skip
            }
            else {
                Write-Warn "HTTP $code on $Uri — $($_.Exception.Message)"
                return $null
            }
        }
    }
    Write-Bad "Max retries exhausted: $Uri"
    return $null
}

# Safe property accessor 
function Get-SafeProp {
    param([object]$Obj, [string]$Name)
    if (-not $Obj) { return $null }
    $prop = $Obj.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

# ─────────────────────────────────────────────────────────────────────────────
#  PRIVATE — ENUMERATION
# ─────────────────────────────────────────────────────────────────────────────

function Get-AzSubscriptions {
    param([string]$BearerToken)

    Write-Info "Fetching accessible subscriptions..."
    $uri  = "https://management.azure.com/subscriptions?api-version=2022-12-01"
    $resp = Invoke-AzRestMethod -Uri $uri -Headers (Get-AuthHeaders $BearerToken)

    $value = Get-SafeProp $resp 'value'
    if (-not $value) {
        Write-Bad "No subscriptions returned or request failed."
        return @()
    }

    # @() forces array — prevents scalar .Count crash under strict mode
    $subs = @($value | Where-Object { (Get-SafeProp $_ 'state') -eq "Enabled" })
    Write-Good "Found $($subs.Count) enabled subscription(s)."
    return $subs
}

function Get-AzResources {
    param(
        [string]$BearerToken,
        [string]$SubscriptionId
    )

    $headers   = Get-AuthHeaders $BearerToken
    $resources = [System.Collections.Generic.List[object]]::new()
    $uri       = "https://management.azure.com/subscriptions/$SubscriptionId/resources?api-version=2021-04-01&`$expand=createdTime,changedTime"

    # Paginate via nextLink. PSObject.Properties prevents strict-mode crash when
    # the property is absent (single-page responses omit nextLink entirely).
    do {
        $resp = Invoke-AzRestMethod -Uri $uri -Headers $headers
        if (-not $resp) { break }
        $page = Get-SafeProp $resp 'value'
        if ($page) { $resources.AddRange(@($page)) }
        $next = Get-SafeProp $resp 'nextLink'
        $uri  = if ($next) { $next } else { $null }
    } while ($uri)

    return $resources
}

function Get-ResourcePermissions {
    param(
        [string]$BearerToken,
        [string]$ResourceId
    )

    $empty = [PSCustomObject]@{
        Actions        = [string[]]@()
        NotActions     = [string[]]@()
        DataActions    = [string[]]@()
        NotDataActions = [string[]]@()
    }

    $uri  = "https://management.azure.com$ResourceId/providers/Microsoft.Authorization/permissions?api-version=2022-04-01"
    $resp = Invoke-AzRestMethod -Uri $uri -Headers (Get-AuthHeaders $BearerToken)

    $value = Get-SafeProp $resp 'value'
    if (-not $value) { return $empty }

    # @() on every pipeline output — strict mode throws .Count on a scalar.
    # Get-SafeProp guards against missing fields (e.g. dataActions absent on
    # classic RBAC roles) without tripping strict mode.
    $actions        = [string[]]@($value | ForEach-Object { Get-SafeProp $_ 'actions'        } | Where-Object { $_ } | Sort-Object -Unique)
    $notActions     = [string[]]@($value | ForEach-Object { Get-SafeProp $_ 'notActions'     } | Where-Object { $_ } | Sort-Object -Unique)
    $dataActions    = [string[]]@($value | ForEach-Object { Get-SafeProp $_ 'dataActions'    } | Where-Object { $_ } | Sort-Object -Unique)
    $notDataActions = [string[]]@($value | ForEach-Object { Get-SafeProp $_ 'notDataActions' } | Where-Object { $_ } | Sort-Object -Unique)

    return [PSCustomObject]@{
        Actions        = $actions
        NotActions     = $notActions
        DataActions    = $dataActions
        NotDataActions = $notDataActions
    }
}

# ─────────────────────────────────────────────────────────────────────────────
#  PRIVATE — OUTPUT
# ─────────────────────────────────────────────────────────────────────────────

function Show-ResourceEntry {
    param(
        [string]        $ResourceName,
        [string]        $ResourceType,
        [string]        $ResourceGroup,
        [string]        $Location,
        [PSCustomObject]$Permissions
    )

    # Force all permission arrays — this is the core .Count fix.
    # Under Set-StrictMode -Version Latest a single pipeline result is a scalar,
    
    $actions     = [string[]]@($Permissions.Actions)
    $notActions  = [string[]]@($Permissions.NotActions)
    $dataActions = [string[]]@($Permissions.DataActions)

    $hasWildcard = $actions -contains "*"
    # @() wraps the Where-Object result so $hasWrite is always an array
    $writeItems  = [string[]]@($actions | Where-Object { $_ -match "write|delete|action" -and $_ -notmatch "^Microsoft\.Authorization" })
    $hasWrite    = $writeItems.Count -gt 0
    $hasRead     = ($actions.Count -gt 0) -and (-not $hasWrite) -and (-not $hasWildcard)

    $typeShort = $ResourceType -replace "^[^/]+/", ""

    if ($hasWildcard) {
        Write-Host ""
        Write-Host "    ★  " -ForegroundColor Red -NoNewline
        Write-Host $ResourceName -ForegroundColor White -NoNewline
        Write-Host "  [$typeShort]" -ForegroundColor DarkGray
        Write-Host "       RG: $ResourceGroup  |  $Location" -ForegroundColor DarkGray
        Write-Host "       LEVEL: " -ForegroundColor DarkGray -NoNewline
        Write-Host "FULL CONTROL (wildcard *)" -ForegroundColor Red
    }
    elseif ($hasWrite) {
        Write-Host ""
        Write-Host "    ►  " -ForegroundColor Yellow -NoNewline
        Write-Host $ResourceName -ForegroundColor White -NoNewline
        Write-Host "  [$typeShort]" -ForegroundColor DarkGray
        Write-Host "       RG: $ResourceGroup  |  $Location" -ForegroundColor DarkGray
        Write-Host "       LEVEL: " -ForegroundColor DarkGray -NoNewline
        Write-Host "WRITE / DELETE" -ForegroundColor Yellow
    }
    elseif ($hasRead) {
        Write-Host ""
        Write-Host "    ·  " -ForegroundColor Cyan -NoNewline
        Write-Host $ResourceName -ForegroundColor White -NoNewline
        Write-Host "  [$typeShort]" -ForegroundColor DarkGray
        Write-Host "       RG: $ResourceGroup  |  $Location" -ForegroundColor DarkGray
        Write-Host "       LEVEL: " -ForegroundColor DarkGray -NoNewline
        Write-Host "READ ONLY" -ForegroundColor Cyan
    }
    else {
        Write-Host ""
        Write-Host "    ○  " -ForegroundColor DarkGray -NoNewline
        Write-Host "$ResourceName  [$typeShort]  — NO PERMISSIONS" -ForegroundColor DarkGray
        return
    }

    # Actions (cap at 10, note remainder)
    if ($actions.Count -gt 0) {
        $slice = $actions | Select-Object -First 10
        foreach ($a in $slice) { Write-Host "         [Allow]  $a" -ForegroundColor Green }
        if ($actions.Count -gt 10) {
            Write-Host "         ... +$($actions.Count - 10) more action(s)" -ForegroundColor DarkGray
        }
    }

    # NotActions
    if ($notActions.Count -gt 0) {
        foreach ($na in $notActions) { Write-Host "         [Deny]   $na" -ForegroundColor Red }
    }

    # DataActions (cap at 5)
    if ($dataActions.Count -gt 0) {
        $slice = $dataActions | Select-Object -First 5
        foreach ($da in $slice) { Write-Host "         [Data]   $da" -ForegroundColor Magenta }
        if ($dataActions.Count -gt 5) {
            Write-Host "         ... +$($dataActions.Count - 5) more data action(s)" -ForegroundColor DarkGray
        }
    }
}

function Show-Summary {
    param([System.Collections.Generic.List[object]]$Results)

    Write-Section "ENUMERATION SUMMARY"

    # @() on every Where-Object result — prevents scalar .Count crash
    $total     = $Results.Count
    $wildcards = [object[]]@($Results | Where-Object { @($_.Permissions.Actions) -contains "*" })
    $writers   = [object[]]@($Results | Where-Object {
                     $a = [string[]]@($_.Permissions.Actions)
                     $a -notcontains "*" -and (@($a | Where-Object { $_ -match "write|delete|action" })).Count -gt 0
                 })
    $readers   = [object[]]@($Results | Where-Object {
                     $a = [string[]]@($_.Permissions.Actions)
                     $a -notcontains "*" -and
                     (@($a | Where-Object { $_ -match "write|delete|action" })).Count -eq 0 -and
                     $a.Count -gt 0
                 })
    $noperms   = [object[]]@($Results | Where-Object { (@($_.Permissions.Actions)).Count -eq 0 })

    Write-Host ""
    Write-Host "    Resources Enumerated   :  $total"          -ForegroundColor White
    Write-Host "    Full Control (★)       :  $($wildcards.Count)" -ForegroundColor Red
    Write-Host "    Write / Delete (►)     :  $($writers.Count)"   -ForegroundColor Yellow
    Write-Host "    Read-Only (·)          :  $($readers.Count)"   -ForegroundColor Cyan
    Write-Host "    No Permissions (○)     :  $($noperms.Count)"   -ForegroundColor DarkGray
    Write-Host ""

    if ($wildcards.Count -gt 0) {
        Write-Host "  ╔══ HIGH VALUE TARGETS ══════════════════════════════════════════╗" -ForegroundColor Red
        foreach ($r in $wildcards) {
            $t = $r.Type -replace '^[^/]+/', ''
            Write-Host "  ║  ★  $($r.Name)  [$t]  —  RG: $($r.ResourceGroup)" -ForegroundColor Red
        }
        Write-Host "  ╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Red
    }
}

# ─────────────────────────────────────────────────────────────────────────────
#  PUBLIC — MAIN EXPORTED FUNCTION
# ─────────────────────────────────────────────────────────────────────────────

function Enumerate-AzResources {
<#
.SYNOPSIS
    Enumerates Azure subscriptions, resources, and per-resource permissions
    using a raw ARM Bearer token.

.PARAMETER Token
    Azure ARM Bearer token. 

.PARAMETER ExportJson
    Optional file path to write the full results as a JSON report.

.PARAMETER ThrottleMs
    Delay in milliseconds between permission API calls to avoid 429s (default: 200).

.EXAMPLE
    Enumerate-AzResources -Token $armToken

.EXAMPLE
    Enumerate-AzResources -Token $armToken -ExportJson "C:\ops\run1.json" -ThrottleMs 400
#>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Token,

        [Parameter(Mandatory = $false)]
        [string]$ExportJson,

        [Parameter(Mandatory = $false)]
        [int]$ThrottleMs = 200
    )

    Write-Banner

    $allResults = [System.Collections.Generic.List[object]]::new()

    # ── 1. Subscriptions ─────────────────────────────────────────────────────
    $subscriptions = @(Get-AzSubscriptions -BearerToken $Token)

    if ($subscriptions.Count -eq 0) {
        Write-Bad "No accessible subscriptions found. Verify token scope."
        return
    }

    foreach ($sub in $subscriptions) {
        $subId   = Get-SafeProp $sub 'subscriptionId'
        $subName = Get-SafeProp $sub 'displayName'
        if (-not $subId) { continue }

        Write-Section "Subscription: $subName  ($subId)"

        # ── 2. Resources ─────────────────────────────────────────────────────
        Write-Info "Enumerating resources..."
        $resources = @(Get-AzResources -BearerToken $Token -SubscriptionId $subId)

        if ($resources.Count -eq 0) {
            Write-Warn "No resources found (or insufficient list permissions)."
            continue
        }

        Write-Good "Found $($resources.Count) resource(s). Checking permissions..."

        # Group by type for clean display
        $grouped = @($resources | Group-Object -Property type | Sort-Object Name)

        foreach ($typeGroup in $grouped) {
            Write-Host ""
            Write-Host "  ┌─ " -ForegroundColor DarkGray -NoNewline
            Write-Host $typeGroup.Name -ForegroundColor Magenta

            foreach ($res in $typeGroup.Group) {
                $resId = Get-SafeProp $res 'id'
                $rgParts = "$resId" -split '/resourceGroups/', 2
                $rg = if ($rgParts.Count -gt 1) { ($rgParts[1] -split '/')[0] } else { 'N/A' }
                $locRaw = Get-SafeProp $res 'location'
                $loc    = if ($locRaw) { $locRaw } else { "global" }

                # ── 3. Permissions ────────────────────────────────────────────
                Start-Sleep -Milliseconds $ThrottleMs
                $perms = Get-ResourcePermissions -BearerToken $Token -ResourceId $resId

                Show-ResourceEntry `
                    -ResourceName  (Get-SafeProp $res 'name') `
                    -ResourceType  (Get-SafeProp $res 'type') `
                    -ResourceGroup $rg `
                    -Location      $loc `
                    -Permissions   $perms

                $allResults.Add([PSCustomObject]@{
                    Subscription   = $subName
                    SubscriptionId = $subId
                    ResourceGroup  = $rg
                    Name           = (Get-SafeProp $res 'name')
                    Type           = (Get-SafeProp $res 'type')
                    Location       = $loc
                    ResourceId     = $resId
                    Permissions    = $perms
                })
            }
        }
    }

    # ── 4. Summary ───────────────────────────────────────────────────────────
    Show-Summary -Results $allResults

    # ── 5. JSON export ───────────────────────────────────────────────────────
    if ($ExportJson) {
        try {
            $export = $allResults | Select-Object `
                Subscription, SubscriptionId, ResourceGroup, Name, Type, Location, ResourceId,
                @{N="Actions";        E={ @($_.Permissions.Actions)        -join " | " }},
                @{N="NotActions";     E={ @($_.Permissions.NotActions)     -join " | " }},
                @{N="DataActions";    E={ @($_.Permissions.DataActions)    -join " | " }},
                @{N="NotDataActions"; E={ @($_.Permissions.NotDataActions) -join " | " }}

            $export | ConvertTo-Json -Depth 5 | Out-File -FilePath $ExportJson -Encoding UTF8
            Write-Good "Results exported → $ExportJson"
        }
        catch {
            Write-Bad "JSON export failed: $($_.Exception.Message)"
        }
    }

    Write-Host ""
}

# ─────────────────────────────────────────────────────────────────────────────
