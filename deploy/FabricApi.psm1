<#
.SYNOPSIS
    Minimal Fabric / Power BI REST helpers for Deploy.ps1.
    Windows PowerShell 5.1 compatible. Authentication uses the Azure CLI.
#>

Set-StrictMode -Version Latest
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$script:Tokens = @{}

function Write-Step {
    param([Parameter(Mandatory)][string] $Message,
          [ValidateSet('Info', 'Ok', 'Warn', 'Fail', 'Skip')][string] $Level = 'Info')
    $p = @{ Info = '[ .. ]'; Ok = '[ OK ]'; Warn = '[WARN]'; Fail = '[FAIL]'; Skip = '[SKIP]' }
    $c = @{ Info = 'Cyan'; Ok = 'Green'; Warn = 'Yellow'; Fail = 'Red'; Skip = 'DarkGray' }
    Write-Host "$($p[$Level]) $Message" -ForegroundColor $c[$Level]
}

function Get-AccessToken {
    param([string] $Resource = 'https://api.fabric.microsoft.com')
    $cached = $script:Tokens[$Resource]
    if ($cached -and $cached.Expires -gt (Get-Date).AddMinutes(5)) { return $cached.Token }
    $raw = az account get-access-token --resource $Resource --output json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { throw "Azure CLI token for '$Resource' failed. Run 'az login' first." }
    $t = $raw | ConvertFrom-Json
    $script:Tokens[$Resource] = @{ Token = $t.accessToken; Expires = [datetime]$t.expiresOn }
    return $t.accessToken
}

function Invoke-Api {
    <#
        Calls the Fabric API (default) or the Power BI API (-PowerBI). Follows
        Fabric long-running operations and returns their result. Retries 429/5xx.
    #>
    param([Parameter(Mandatory)][string] $Path,
          [ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')][string] $Method = 'GET',
          [object] $Body,
          [switch] $PowerBI,
          [switch] $NoWait)

    if ($PowerBI) {
        $root = 'https://api.powerbi.com/v1.0/myorg'
        $token = Get-AccessToken 'https://analysis.windows.net/powerbi/api'
    } else {
        $root = 'https://api.fabric.microsoft.com/v1'
        $token = Get-AccessToken
    }
    $uri = if ($Path -match '^https://') { $Path } else { "$root/$($Path.TrimStart('/'))" }
    $headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json'; 'x-ms-fabric-skill' = 'semantic-model-authoring' }
    $json = if ($null -ne $Body) { $Body | ConvertTo-Json -Depth 30 -Compress } else { $null }

    for ($attempt = 1; ; $attempt++) {
        try {
            $p = @{ Uri = $uri; Method = $Method; Headers = $headers; UseBasicParsing = $true; ErrorAction = 'Stop' }
            if ($json) { $p.Body = [Text.Encoding]::UTF8.GetBytes($json) }
            $r = Invoke-WebRequest @p
            if ($r.StatusCode -eq 202 -and -not $NoWait -and -not $PowerBI) {
                $loc = @($r.Headers['Location'])[0]
                if ($loc) { return (Wait-Operation -Uri $loc) }
            }
            if ($NoWait) { return $r }
            if ([string]::IsNullOrWhiteSpace($r.Content)) { return $null }
            return ($r.Content | ConvertFrom-Json)
        } catch {
            $status = $null
            try { $status = [int]$_.Exception.Response.StatusCode } catch { }
            $detail = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
            if ($status -in 429, 500, 502, 503, 504 -and $attempt -lt 5) {
                Start-Sleep -Seconds ([Math]::Pow(2, $attempt) * 3)
                continue
            }
            throw "$Method $uri failed (HTTP $status): $detail"
        }
    }
}

function Wait-Operation {
    param([Parameter(Mandatory)][string] $Uri, [int] $TimeoutSeconds = 900)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        $o = Invoke-Api -Path $Uri
        if ($o.status -eq 'Succeeded') {
            try { return (Invoke-Api -Path ($Uri.TrimEnd('/') + '/result')) } catch { return $o }
        }
        if ($o.status -eq 'Failed') { throw "Operation failed: $($o.error | ConvertTo-Json -Depth 10 -Compress)" }
    }
    throw "Operation timed out: $Uri"
}

function Get-ByName {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Name, [switch] $PowerBI)
    $field = if ($PowerBI) { 'name' } else { 'displayName' }
    $next = $Path
    while ($next) {
        $r = Invoke-Api -Path $next -PowerBI:$PowerBI
        $hit = $r.value | Where-Object { $_.$field -eq $Name } | Select-Object -First 1
        if ($hit) { return $hit }
        $next = $null
        if ($r.PSObject.Properties['continuationUri'] -and $r.continuationUri) { $next = $r.continuationUri }
    }
    return $null
}

function ConvertFrom-DefinitionParts {
    # Fabric definition parts -> ordered hashtable path -> UTF-8 text (or byte[] for binaries).
    param([Parameter(Mandatory)] $Parts)
    $map = [ordered]@{}
    foreach ($p in $Parts) {
        $bytes = [Convert]::FromBase64String($p.payload)
        if ($p.path -match '\.(png|jpg|jpeg|gif|svg|ico)$') { $map[$p.path] = $bytes }
        else { $map[$p.path] = [Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF) }
    }
    return $map
}

function ConvertTo-DefinitionParts {
    param([Parameter(Mandatory)] $Map)
    foreach ($k in $Map.Keys) {
        $v = $Map[$k]
        $bytes = if ($v -is [byte[]]) { $v } else { [Text.Encoding]::UTF8.GetBytes([string]$v) }
        @{ path = $k; payload = [Convert]::ToBase64String($bytes); payloadType = 'InlineBase64' }
    }
}

Export-ModuleMember -Function Write-Step, Get-AccessToken, Invoke-Api, Wait-Operation, Get-ByName, ConvertFrom-DefinitionParts, ConvertTo-DefinitionParts
