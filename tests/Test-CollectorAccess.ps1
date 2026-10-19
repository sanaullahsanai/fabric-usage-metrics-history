$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\deploy\FabricApi.psm1') -Force

$tenant = '11111111-1111-1111-1111-111111111111'
$userId = '22222222-2222-2222-2222-222222222222'
$claims = [pscustomobject]@{
    tid = $tenant; oid = $userId; upn = 'collector@example.invalid'
    scp = 'user_impersonation'
}
$identity = Get-CollectorIdentity -Claims $claims -TenantId $tenant -UserObjectId $userId -UserPrincipalName 'COLLECTOR@example.invalid'
if ($identity.UserObjectId -ne $userId) { throw 'Matching identity was not returned.' }

function Assert-Rejected {
    param([scriptblock] $Action, [string] $Expected)
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_ }
    if (-not $caught) { throw "Expected identity rejection: $Expected" }
    if ($caught.Exception.Message -notlike "*$Expected*") {
        throw "Unexpected rejection: $($caught.Exception.Message)"
    }
}

Assert-Rejected { Get-CollectorIdentity -Claims $claims -TenantId 'invalid' } 'Entra GUID'
Assert-Rejected { Get-CollectorIdentity -Claims $claims -UserObjectId 'invalid' } 'Entra GUID'
Assert-Rejected { Get-CollectorIdentity -Claims $claims -TenantId $userId } 'different tenant'
Assert-Rejected { Get-CollectorIdentity -Claims $claims -UserObjectId $tenant } 'different user object'
Assert-Rejected { Get-CollectorIdentity -Claims $claims -UserPrincipalName 'wrong@example.invalid' } 'different user principal'
Assert-Rejected { Get-CollectorIdentity -Claims ([pscustomobject]@{ tid = $tenant }) } 'tenant and user object'
Assert-Rejected {
    Get-CollectorIdentity -Claims ([pscustomobject]@{ tid = $tenant; oid = $userId; idtyp = 'app' })
} 'delegated user authentication'

$fallback = [pscustomobject]@{
    tid = $tenant; oid = $userId; preferred_username = 'collector@example.invalid'
    scp = 'Tenant.Read.All'
}
Get-CollectorIdentity -Claims $fallback -UserPrincipalName 'collector@example.invalid' | Out-Null
Write-Output 'Collector identity validation checks passed.'
