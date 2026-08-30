<#
APIM TEST TOOL
Azure Private Endpoint Connectivity Validator
PowerShell version 1.1.0
#>

$ErrorActionPreference = "Stop"
$Version = "1.1.0"
$script:PassCount = 0
$script:WarnCount = 0
$script:FailCount = 0

function Banner {
    Clear-Host
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "                     APIM TEST TOOL" -ForegroundColor Cyan
    Write-Host "       Azure Private Endpoint Connectivity Validator" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Version: $Version"
}

function Section([string]$Title) {
    Write-Host ""
    Write-Host "------------------------------------------------------------" -ForegroundColor Blue
    Write-Host $Title -ForegroundColor Blue
    Write-Host "------------------------------------------------------------" -ForegroundColor Blue
}

function Pass([string]$Message) {
    $script:PassCount++
    Write-Host "[PASS] " -ForegroundColor Green -NoNewline
    Write-Host $Message
}

function Warn([string]$Message) {
    $script:WarnCount++
    Write-Host "[WARN] " -ForegroundColor Yellow -NoNewline
    Write-Host $Message
}

function Fail([string]$Message) {
    $script:FailCount++
    Write-Host "[FAIL] " -ForegroundColor Red -NoNewline
    Write-Host $Message
}

function Info([string]$Message) {
    Write-Host "[INFO] " -ForegroundColor Cyan -NoNewline
    Write-Host $Message
}

function Mask-Url([string]$Url) {
    return [regex]::Replace(
        $Url,
        '([?&](sig|code|token|key|subscription-key)=)[^&]+',
        '$1***REDACTED***',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
}

function Normalize-BaseUrl([string]$Url) {
    return $Url.TrimEnd('/')
}

function Normalize-Path([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return "/" }
    if ($Path.StartsWith("/")) { return $Path }
    return "/$Path"
}

function Get-HostFromUrl([string]$Url) {
    try { return ([uri]$Url).Host } catch { return "" }
}

function Is-PrivateIPv4([string]$Ip) {
    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($Ip, [ref]$parsed)) { return $false }
    if ($parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { return $false }
    $b = $parsed.GetAddressBytes()
    if ($b[0] -eq 10) { return $true }
    if ($b[0] -eq 192 -and $b[1] -eq 168) { return $true }
    if ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) { return $true }
    return $false
}

function Show-HttpRemediation([string]$Component, [string]$Status) {
    Write-Host ""
    Write-Host "Remediation:" -ForegroundColor Yellow

    switch ($Component) {
        "Logic App" {
            Write-Host "  1. Open Logic App Standard > Workflows > Run history."
            Write-Host "  2. Inspect the first failed action."
            Write-Host "  3. For private Blob Storage use the Built-in Azure Blob Storage connector."
            Write-Host "  4. Confirm Upload blob Content is populated, e.g. string(triggerBody())."
            Write-Host "  5. Confirm Logic App VNet Integration is enabled."
            Write-Host "  6. Confirm Storage resolves to the Storage Private Endpoint IP."
            Write-Host "  7. Check NSG, UDR, Azure Firewall/NVA and TCP 443."
            Write-Host "  8. Verify Storage authentication/RBAC."
        }
        "Function App" {
            Write-Host "  1. Test the Logic App directly first."
            Write-Host "  2. Verify the Function route (/api/test by default)."
            Write-Host "  3. Confirm Function App VNet Integration is enabled."
            Write-Host "  4. Confirm Logic App DNS resolves to its Private Endpoint."
            Write-Host "  5. Verify LOGIC_APP_URL is configured and has no surrounding quotes."
            Write-Host "  6. Confirm Logic App Private Endpoint is Approved."
            Write-Host "  7. Review Function logs/Application Insights."
            Write-Host "  8. Check NSG, UDR, Firewall/NVA and TCP 443."
        }
        "API Management" {
            Write-Host "  1. Test the Function App directly first."
            Write-Host "  2. Verify APIM API suffix and operation path."
            Write-Host "  3. Confirm APIM outbound VNet Integration is enabled."
            Write-Host "  4. Confirm Function DNS resolves to its Private Endpoint."
            Write-Host "  5. Verify APIM backend URL points to the Function base URL."
            Write-Host "  6. Check rewrite-uri, set-backend-service and auth policies."
            Write-Host "  7. Use APIM Test Console > Trace."
            Write-Host "  8. Check NSG, UDR, Firewall/NVA and TCP 443."
        }
    }

    switch ($Status) {
        "401" { Write-Host "  9. HTTP 401: check authentication/subscription key/authorization." }
        "403" { Write-Host "  9. HTTP 403: check access restrictions and authorization." }
        "404" { Write-Host "  9. HTTP 404: verify the full operation URL and route." }
        "408" { Write-Host "  9. HTTP 408: investigate DNS, routing and timeout." }
        "500" { Write-Host "  9. HTTP 500: test downstream components independently." }
        "502" { Write-Host "  9. HTTP 502: isolate the failing downstream hop." }
        "503" { Write-Host "  9. HTTP 503: check backend health/connectivity." }
        "504" { Write-Host "  9. HTTP 504: investigate DNS, routing, firewall and backend timeout." }
    }
}

function Invoke-HttpCheck {
    param(
        [string]$Component,
        [string]$Url,
        [hashtable]$Body,
        [string]$ExpectedText
    )

    Section "HTTP Test - $Component"
    Info "Endpoint: $(Mask-Url $Url)"

    $json = $Body | ConvertTo-Json -Depth 10 -Compress

    try {
        $r = Invoke-WebRequest -Uri $Url -Method POST -ContentType "application/json" `
            -Body $json -TimeoutSec 45 -UseBasicParsing -ErrorAction Stop

        $code = [int]$r.StatusCode
        $content = [string]$r.Content

        Write-Host "  HTTP Status: $code"
        Write-Host "  Response:"
        if ([string]::IsNullOrWhiteSpace($content)) {
            Write-Host "    <empty>"
        } else {
            $content -split "`r?`n" | ForEach-Object { Write-Host "    $_" }
        }

        if ($code -lt 200 -or $code -ge 300) {
            Fail "$Component returned HTTP $code."
            Show-HttpRemediation $Component "$code"
            return $false
        }

        if ($content.IndexOf($ExpectedText, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
            Fail "$Component returned HTTP $code but the expected application response was not found."
            Write-Host "  Expected response to contain: $ExpectedText"
            Write-Host "  The BASE URL may have been called instead of the API operation route."
            Show-HttpRemediation $Component "404"
            return $false
        }

        Pass "$Component returned the expected HTTP $code application response."
        return $true
    }
    catch {
        $code = $null
        try { $code = [int]$_.Exception.Response.StatusCode } catch {}

        if ($code) {
            Fail "$Component returned HTTP $code."
            Show-HttpRemediation $Component "$code"
        } else {
            Fail "$Component request failed: $($_.Exception.Message)"
            Show-HttpRemediation $Component "000"
        }
        return $false
    }
}

function Show-DnsRemediation([string]$Label, [string]$Zone) {
    Write-Host ""
    Write-Host "DNS remediation:" -ForegroundColor Yellow
    Write-Host "  1. Confirm the $Label Private Endpoint exists and is Approved."
    Write-Host "  2. Confirm the A record exists in $Zone."
    Write-Host "  3. Confirm this Windows machine can resolve that private zone."
    Write-Host "  4. In hub-and-spoke, verify custom DNS/Azure DNS Private Resolver forwarding."
    Write-Host "  5. Verify VNet peering and DNS reachability."
    Write-Host "  6. Check NSGs/UDRs/firewall if DNS is correct but connectivity still fails."
}

function Invoke-DnsCheck {
    param(
        [string]$Label,
        [string]$Hostname,
        [string]$ExpectedZone
    )

    Section "DNS Test - $Label"
    Info "Hostname: $Hostname"

    $cname = $null
    $ips = @()

    try {
        $c = Resolve-DnsName -Name $Hostname -Type CNAME -ErrorAction SilentlyContinue |
            Where-Object { $_.Type -eq "CNAME" -and $_.NameHost } |
            Select-Object -First 1
        if ($c) { $cname = $c.NameHost.TrimEnd('.') }
    } catch {}

    try {
        $ips = @(
            Resolve-DnsName -Name $Hostname -Type A -ErrorAction Stop |
            Where-Object { $_.Type -eq "A" -and $_.IPAddress } |
            Select-Object -ExpandProperty IPAddress -Unique
        )
    } catch {}

    if ($cname) { Write-Host "  CNAME: $cname" }
    else { Write-Host "  CNAME: none detected" }

    if (-not $ips -or $ips.Count -eq 0) {
        Fail "${Label}: no IPv4 address resolved."
        Show-DnsRemediation $Label $ExpectedZone
        return $false
    }

    Write-Host "  Resolved IPv4 address(es):"
    $ips | ForEach-Object { Write-Host "    - $_" }

    $private = $false
    foreach ($ip in $ips) {
        if (Is-PrivateIPv4 $ip) { $private = $true; break }
    }

    if ($private) {
        Pass "${Label}: resolves to a private IPv4 address."
    } else {
        Fail "${Label}: no RFC1918 private IPv4 address detected."
        Show-DnsRemediation $Label $ExpectedZone
        return $false
    }

    if ($cname -and $cname.IndexOf($ExpectedZone, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        Pass "${Label}: CNAME uses expected private-link zone '$ExpectedZone'."
    } else {
        Warn "${Label}: expected private-link CNAME '$ExpectedZone' was not detected."
        Write-Host "  This may be valid with custom enterprise DNS, but verify the intended DNS design."
    }

    return $true
}

# ---------------- Main ----------------

Banner
Section "Prerequisite Check"

if (Get-Command Invoke-WebRequest -ErrorAction SilentlyContinue) {
    Pass "PowerShell HTTP client is available."
} else {
    Fail "Invoke-WebRequest is unavailable."
    exit 1
}

if (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue) {
    Pass "Resolve-DnsName is available."
} else {
    Fail "Resolve-DnsName is unavailable. Run from Windows PowerShell/PowerShell on Windows."
    exit 1
}

Section "Configuration"

Write-Host "Enter the Logic App FULL trigger URL."
$LogicAppUrl = Read-Host "Logic App HTTP trigger URL"

Write-Host ""
Write-Host "Enter the Function App BASE URL only."
Write-Host "Example: https://func-name.azurewebsites.net"
$FunctionBase = Read-Host "Function App base URL"
$FunctionPath = Read-Host "Function operation path [/api/test]"
if ([string]::IsNullOrWhiteSpace($FunctionPath)) { $FunctionPath = "/api/test" }

Write-Host ""
Write-Host "Enter the APIM gateway BASE URL only."
Write-Host "Example: https://apim-name.azure-api.net"
$ApimBase = Read-Host "APIM gateway base URL"
$ApimPath = Read-Host "APIM API operation path [/debug/api/test]"
if ([string]::IsNullOrWhiteSpace($ApimPath)) { $ApimPath = "/debug/api/test" }

$StorageAccount = Read-Host "Storage account name"
$TestId = Read-Host "Test ID [APIM-TEST-001]"
if ([string]::IsNullOrWhiteSpace($TestId)) { $TestId = "APIM-TEST-001" }

$FunctionBase = Normalize-BaseUrl $FunctionBase
$ApimBase = Normalize-BaseUrl $ApimBase
$FunctionPath = Normalize-Path $FunctionPath
$ApimPath = Normalize-Path $ApimPath

$FunctionUrl = "$FunctionBase$FunctionPath"
$ApimUrl = "$ApimBase$ApimPath"

$LogicHost = Get-HostFromUrl $LogicAppUrl
$FunctionHost = Get-HostFromUrl $FunctionBase
$ApimHost = Get-HostFromUrl $ApimBase
$StorageHost = "$StorageAccount.blob.core.windows.net"

$Timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

$LogicBody = @{
    receivedAt = $Timestamp
    source = "APIM-Test-Tool"
    data = @{
        message = "Direct Logic App Test"
        testId = "$TestId-LOGIC"
    }
}

$FunctionBody = @{
    message = "Function App Test"
    source = "APIM-Test-Tool"
    testId = "$TestId-FUNCTION"
}

$ApimBody = @{
    message = "End-to-End APIM Test"
    source = "APIM-Test-Tool"
    testId = "$TestId-APIM"
}

Section "Configuration Summary"
Write-Host "Logic App:"
Write-Host "  $(Mask-Url $LogicAppUrl)"
Write-Host ""
Write-Host "Function App:"
Write-Host "  Base URL : $FunctionBase"
Write-Host "  Path     : $FunctionPath"
Write-Host "  Test URL : $FunctionUrl"
Write-Host ""
Write-Host "API Management:"
Write-Host "  Base URL : $ApimBase"
Write-Host "  Path     : $ApimPath"
Write-Host "  Test URL : $ApimUrl"
Write-Host ""
Write-Host "Storage:"
Write-Host "  $StorageAccount"
Write-Host ""
Write-Host "Test ID:"
Write-Host "  $TestId"

$confirm = Read-Host "Start tests? [Y/n]"
if ([string]::IsNullOrWhiteSpace($confirm)) { $confirm = "Y" }
if ($confirm -notmatch '^[Yy]$') { Write-Host "Test cancelled."; exit 0 }

$LogicOk = Invoke-HttpCheck "Logic App" $LogicAppUrl $LogicBody '"status":"saved"'
$FunctionOk = Invoke-HttpCheck "Function App" $FunctionUrl $FunctionBody '"status": "success"'
$ApimOk = Invoke-HttpCheck "API Management" $ApimUrl $ApimBody '"status": "success"'

Invoke-DnsCheck "API Management" $ApimHost "privatelink.azure-api.net" | Out-Null
Invoke-DnsCheck "Function App" $FunctionHost "privatelink.azurewebsites.net" | Out-Null
Invoke-DnsCheck "Logic App" $LogicHost "privatelink.azurewebsites.net" | Out-Null
Invoke-DnsCheck "Storage Blob" $StorageHost "privatelink.blob.core.windows.net" | Out-Null

Section "Fault Isolation"

if (-not $LogicOk) {
    Write-Host "Likely failing hop: Logic App -> Storage" -ForegroundColor Red
    Write-Host "Prioritize:"
    Write-Host "  - Logic App Run History"
    Write-Host "  - Built-in Blob connector"
    Write-Host "  - Blob Content field"
    Write-Host "  - Logic App VNet Integration"
    Write-Host "  - Storage Private Endpoint / DNS"
    Write-Host "  - NSG / UDR / Firewall / NVA"
}
elseif (-not $FunctionOk) {
    Write-Host "Likely failing hop: Function App -> Logic App" -ForegroundColor Red
    Write-Host "Prioritize:"
    Write-Host "  - Function VNet Integration"
    Write-Host "  - LOGIC_APP_URL"
    Write-Host "  - Logic App Private Endpoint / DNS"
    Write-Host "  - NSG / UDR / Firewall / NVA"
}
elseif (-not $ApimOk) {
    Write-Host "Likely failing hop: APIM -> Function App" -ForegroundColor Red
    Write-Host "Prioritize:"
    Write-Host "  - APIM operation path"
    Write-Host "  - APIM backend URL"
    Write-Host "  - APIM VNet Integration"
    Write-Host "  - Function Private Endpoint / DNS"
    Write-Host "  - APIM policies"
    Write-Host "  - NSG / UDR / Firewall / NVA"
}
else {
    Write-Host "HTTP application chain is healthy." -ForegroundColor Green
}

Section "Test Summary"
Write-Host "Passed   : $script:PassCount" -ForegroundColor Green
Write-Host "Warnings : $script:WarnCount" -ForegroundColor Yellow
Write-Host "Failed   : $script:FailCount" -ForegroundColor Red

if ($script:FailCount -eq 0) {
    Write-Host ""
    Write-Host "RESULT: ALL TESTS PASSED" -ForegroundColor Green
    exit 0
} else {
    Write-Host ""
    Write-Host "RESULT: TROUBLESHOOTING REQUIRED" -ForegroundColor Red
    Write-Host "Start with the first failing hop shown above."
    exit 2
}
