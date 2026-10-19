<#
.SYNOPSIS
    Deploys Usage Metrics History end to end. Safe to re-run.

.DESCRIPTION
     1. Workspace on the capacity, with a workspace identity
     2. Lakehouse (and its SQL analytics endpoint)
     3. Tenant-wide Activity Events notebook with settings + daily schedule
     4. First notebook run (creates audit_* tables without touching old snapshots)
     5. Cloud connection to the SQL endpoint using the workspace identity
     6. First-party semantic model reading retained report-open audit events
     7. Report usage, report list, and collection coverage report pages

    Settings come from config\settings.json (copy config\settings.example.json).

.EXAMPLE
    az login
    .\deploy\Deploy.ps1
    .\deploy\Deploy.ps1 -SkipNotebookRun     # e.g. after changing only the schedule
#>
[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path $PSScriptRoot '..\config\settings.json'),
    [switch] $SkipNotebookRun,
    [switch] $PreflightOnly,
    [int]    $TimeoutMinutes = 45
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'FabricApi.psm1') -Force
$repoRoot = Split-Path $PSScriptRoot -Parent

# ----------------------------------------------------------------------------
# Settings
# ----------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Config not found: $ConfigPath. Copy config\settings.example.json to config\settings.json and edit it."
}
$cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

function Get-Setting([string] $Name, $Default) {
    $p = $cfg.PSObject.Properties[$Name]
    if ($p -and $null -ne $p.Value -and "$($p.Value)" -ne '') { return $p.Value }
    return $Default
}

$wsName      = Get-Setting 'workspaceName' 'WS-UsageMetrics'
$capName     = Get-Setting 'capacityName' ''
$capId       = Get-Setting 'capacityId' ''
$lhName      = Get-Setting 'lakehouseName' 'LH_UsageMetrics'
$nbName      = Get-Setting 'notebookName' 'NB_UsageMetricsHistory'
$modelName   = Get-Setting 'semanticModelName' 'Tenant Usage Metrics'
$reportName  = Get-Setting 'reportName' 'Usage Metrics History'
$connName    = Get-Setting 'connectionName' "$wsName-$lhName-SQL"
$retention   = [int](Get-Setting 'retentionDays' 730)
$backfill    = [int](Get-Setting 'backfillDays' 27)
$replay      = [int](Get-Setting 'replayDays' 3)
$schedTime   = [string](Get-Setting 'scheduleTime' '05:00')
$schedTz     = [string](Get-Setting 'scheduleTimeZone' 'UTC')
$expose      = Get-Setting 'exposeIdentity' $false
$tenantId    = [string](Get-Setting 'tenantId' '')
$collectorId = [string](Get-Setting 'collectorUserObjectId' '')
$collectorUpn = [string](Get-Setting 'collectorUserPrincipalName' '')

# Pin the scheduled notebook to the user validated by the live API, even when
# optional identity settings are left empty (use the current Azure CLI login).
$collector = Test-CollectorAccess -TenantId $tenantId -UserObjectId $collectorId -UserPrincipalName $collectorUpn
if ($PreflightOnly) {
    $collector
    return
}

if (-not $capName -and -not $capId) { throw "Set capacityName or capacityId in $ConfigPath." }
if ($retention -lt 0) { throw "retentionDays must be 0 (keep forever) or a positive number of days." }
if ($backfill -lt 1 -or $backfill -gt 27) { throw 'backfillDays must be between 1 and 27.' }
if ($replay -lt 1 -or $replay -gt 27) { throw 'replayDays must be between 1 and 27.' }
if ($expose -isnot [bool]) { throw 'exposeIdentity must be a JSON boolean.' }
if ($retention -gt 0 -and $retention -lt 31) { Write-Step "retentionDays=$retention keeps less than the 30 days the built-in report already has." 'Warn' }
if ($schedTime -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { throw "scheduleTime must be HH:mm (24h), not '$schedTime'." }
try { [void][TimeZoneInfo]::FindSystemTimeZoneById($schedTz) } catch { throw "scheduleTimeZone '$schedTz' is not a Windows time zone id (e.g. 'UTC', 'AUS Eastern Standard Time'). List them with: Get-TimeZone -ListAvailable" }
if ($cfg.PSObject.Properties['sourceWorkspaces'] -or $cfg.PSObject.Properties['templateWorkspace']) {
    Write-Step 'sourceWorkspaces/templateWorkspace are obsolete: collection now covers the whole tenant.' 'Warn'
}
$legacy = Get-ByName -Path 'workspaces' -Name $wsName
if ($legacy) {
    $existing = Get-ByName -Path "workspaces/$($legacy.id)/semanticModels" -Name $modelName
    if ($existing) {
        $existingDefinition = Invoke-Api -Path "workspaces/$($legacy.id)/semanticModels/$($existing.id)/getDefinition?format=TMDL" -Method POST
        if ($existingDefinition.definition.parts.path -contains 'definition/tables/Report page views.tmdl') {
            throw "The existing '$modelName' is the legacy XMLA model. Set semanticModelName to a new name such as 'Tenant Usage Metrics'. Its calculated partitions cannot be replaced in place."
        }
    }
}

& python --version | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Python 3 is required to build the model and report definitions.' }

$retentionText = if ($retention -eq 0) { 'forever' } else { "$retention days" }
Write-Host ''
Write-Host "=== Usage Metrics History -> '$wsName' ===" -ForegroundColor White
Write-Step "Source: tenant-wide Admin Activity Events | retention: $retentionText | daily at $schedTime ($schedTz)"

# ----------------------------------------------------------------------------
# 1. Workspace, capacity, identity
# ----------------------------------------------------------------------------

if ($capId) {
    $cap = (Invoke-Api -Path 'capacities').value | Where-Object { $_.id -eq $capId } | Select-Object -First 1
} else {
    $cap = (Invoke-Api -Path 'capacities').value | Where-Object { $_.displayName -eq $capName } | Select-Object -First 1
}
if (-not $cap) { throw "Capacity '$capName$capId' not found or you are not a capacity admin/contributor." }
if ($cap.state -ne 'Active') { throw "Capacity '$($cap.displayName)' is $($cap.state). Resume it and re-run." }

$ws = Get-ByName -Path 'workspaces' -Name $wsName
if (-not $ws) {
    $ws = Invoke-Api -Path 'workspaces' -Method POST -Body @{ displayName = $wsName; capacityId = $cap.id; description = 'Tenant-wide report usage from Power BI Admin Activity Events.' }
    Write-Step "Created workspace '$wsName' ($($ws.id))." 'Ok'
} else {
    Write-Step "Workspace '$wsName' exists ($($ws.id))." 'Skip'
    if ($ws.PSObject.Properties['capacityId'] -and $ws.capacityId -ne $cap.id) {
        Invoke-Api -Path "workspaces/$($ws.id)/assignToCapacity" -Method POST -Body @{ capacityId = $cap.id } | Out-Null
        Write-Step "Assigned to capacity '$($cap.displayName)'." 'Ok'
    }
}
$wsId = $ws.id

$wsDetail = Invoke-Api -Path "workspaces/$wsId"
if (-not ($wsDetail.PSObject.Properties['workspaceIdentity'] -and $wsDetail.workspaceIdentity)) {
    Invoke-Api -Path "workspaces/$wsId/provisionIdentity" -Method POST -NoWait | Out-Null
    $deadline = (Get-Date).AddMinutes(5)
    do {
        Start-Sleep -Seconds 10
        $wsDetail = Invoke-Api -Path "workspaces/$wsId"
    } while (-not ($wsDetail.PSObject.Properties['workspaceIdentity'] -and $wsDetail.workspaceIdentity) -and (Get-Date) -lt $deadline)
    if (-not $wsDetail.workspaceIdentity) { throw 'Workspace identity was not provisioned in time. Re-run.' }
    Write-Step "Provisioned workspace identity." 'Ok'
}
$identitySp = $wsDetail.workspaceIdentity.servicePrincipalId

# The identity reads the lakehouse through the SQL endpoint.
$roles = (Invoke-Api -Path "workspaces/$wsId/roleAssignments").value
if (-not ($roles | Where-Object { $_.principal.id -eq $identitySp })) {
    Invoke-Api -Path "workspaces/$wsId/roleAssignments" -Method POST -Body @{ principal = @{ id = $identitySp; type = 'ServicePrincipal' }; role = 'Contributor' } | Out-Null
    Write-Step 'Granted the workspace identity Contributor on the workspace.' 'Ok'
}

# ----------------------------------------------------------------------------
# 2. Lakehouse
# ----------------------------------------------------------------------------

$lh = Get-ByName -Path "workspaces/$wsId/lakehouses" -Name $lhName
if (-not $lh) {
    Invoke-Api -Path "workspaces/$wsId/lakehouses" -Method POST -Body @{ displayName = $lhName } | Out-Null
    Write-Step "Created lakehouse '$lhName'." 'Ok'
}
$deadline = (Get-Date).AddMinutes(10)
do {
    $lh = Get-ByName -Path "workspaces/$wsId/lakehouses" -Name $lhName
    $sqlProps = if ($lh -and $lh.properties.PSObject.Properties['sqlEndpointProperties']) { $lh.properties.sqlEndpointProperties } else { $null }
    $ready = $sqlProps -and $sqlProps.provisioningStatus -eq 'Success' -and $sqlProps.connectionString
    if (-not $ready) { Start-Sleep -Seconds 15 }
} while (-not $ready -and (Get-Date) -lt $deadline)
if (-not $ready) { throw "The SQL endpoint of '$lhName' is not ready yet. Re-run in a few minutes." }
$sqlServer = $sqlProps.connectionString
Write-Step "Lakehouse '$lhName' ($($lh.id)), SQL endpoint ready." 'Ok'

# ----------------------------------------------------------------------------
# 3. Notebook + schedule
# ----------------------------------------------------------------------------

function ConvertTo-PyString([string] $s) { '"' + ($s -replace '\\', '\\' -replace '"', '\"') + '"' }

function ConvertTo-NotebookCells([string] $Text) {
    # Split on the three-line section banners (rule, title, rule).
    $lines = $Text -split "`r?`n"
    $rule = '^#\s-{20,}\s*$'
    $cells = @()
    $buf = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $banner = ($lines[$i] -match $rule) -and ($i + 2 -lt $lines.Count) -and ($lines[$i + 1] -match '^#') -and ($lines[$i + 2] -match $rule)
        if ($banner -and $buf.Count -gt 0) { $cells += , ($buf -join "`n"); $buf = New-Object System.Collections.Generic.List[string] }
        $buf.Add($lines[$i])
    }
    if ($buf.Count -gt 0) { $cells += , ($buf -join "`n") }
    $cells | ForEach-Object { $_.TrimEnd() }
}

$py = Get-Content -LiteralPath (Join-Path $repoRoot 'src\notebook\usage_metrics_history.py') -Raw
$params = [ordered]@{
    RETENTION_DAYS      = "$retention"
    BACKFILL_DAYS       = "$backfill"
    REPLAY_DAYS         = "$replay"
    EXPOSE_IDENTITY     = $(if ($expose) { 'True' } else { 'False' })
    SEMANTIC_MODEL_NAME = (ConvertTo-PyString $modelName)
    EXPECTED_TENANT_ID  = (ConvertTo-PyString $collector.TenantId)
    COLLECTOR_USER_OBJECT_ID = (ConvertTo-PyString $collector.UserObjectId)
}
foreach ($k in $params.Keys) {
    $pattern = "(?m)^$k = .*$"
    if ($py -notmatch $pattern) { throw "Parameter line '$k = ...' not found in the notebook source." }
    $py = [regex]::Replace($py, $pattern, ("$k = $($params[$k])").Replace('$', '$$'))
}

$nbCells = foreach ($c in (ConvertTo-NotebookCells $py)) {
    [ordered]@{ cell_type = 'code'; source = @($c -split "`n" | ForEach-Object { "$_`n" }); metadata = @{}; outputs = @(); execution_count = $null }
}
$ipynb = [ordered]@{
    nbformat = 4; nbformat_minor = 5; cells = @($nbCells)
    metadata = [ordered]@{
        language_info = @{ name = 'python' }
        kernelspec    = @{ name = 'synapse_pyspark'; display_name = 'Synapse PySpark' }
        dependencies  = @{ lakehouse = [ordered]@{ default_lakehouse = $lh.id; default_lakehouse_name = $lhName; default_lakehouse_workspace_id = $wsId } }
    }
}
$nbDef = @{ format = 'ipynb'; parts = @(@{ path = 'notebook-content.ipynb'; payloadType = 'InlineBase64'
            payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($ipynb | ConvertTo-Json -Depth 30))) }) }

$nb = Get-ByName -Path "workspaces/$wsId/notebooks" -Name $nbName
if ($nb) {
    Invoke-Api -Path "workspaces/$wsId/notebooks/$($nb.id)/updateDefinition" -Method POST -Body @{ definition = $nbDef } | Out-Null
    Write-Step "Updated notebook '$nbName'." 'Ok'
} else {
    Invoke-Api -Path "workspaces/$wsId/notebooks" -Method POST -Body @{ displayName = $nbName; description = 'Tenant-wide Power BI report usage via Admin Activity Events REST API.'; definition = $nbDef } | Out-Null
    $nb = Get-ByName -Path "workspaces/$wsId/notebooks" -Name $nbName
    Write-Step "Created notebook '$nbName' ($($nb.id))." 'Ok'
}

$schedPath = "workspaces/$wsId/items/$($nb.id)/jobs/RunNotebook/schedules"
foreach ($s in @((Invoke-Api -Path $schedPath).value)) {
    if ($s) { Invoke-Api -Path "$schedPath/$($s.id)" -Method DELETE | Out-Null }
}
$now = (Get-Date).ToUniversalTime()
Invoke-Api -Path $schedPath -Method POST -Body @{
    enabled       = $true
    configuration = @{
        type            = 'Daily'
        times           = @($schedTime)
        startDateTime   = $now.ToString('yyyy-MM-ddT00:00:00')
        endDateTime     = $now.AddYears(10).ToString('yyyy-MM-ddT00:00:00')
        localTimeZoneId = $schedTz
    }
} | Out-Null
Write-Step "Scheduled '$nbName' daily at $schedTime ($schedTz)." 'Ok'

# ----------------------------------------------------------------------------
# 4. First run
# ----------------------------------------------------------------------------

if (-not $SkipNotebookRun) {
    $recent = @((Invoke-Api -Path "workspaces/$wsId/items/$($nb.id)/jobs/instances").value |
        Where-Object { $_.status -in 'NotStarted', 'InProgress' })
    if ($recent.Count) { throw "A notebook run is already active. Wait for it before deploying." }
    # Bootstrap the tables before the new model exists; enable refresh after deployment.
    $bootstrapText = $py -replace '(?m)^SEMANTIC_MODEL_NAME = .*$', 'SEMANTIC_MODEL_NAME = ""'
    $bootstrap = $ipynb | ConvertTo-Json -Depth 30 | ConvertFrom-Json
    $bootstrap.cells = @([ordered]@{
        cell_type = 'code'; source = @($bootstrapText -split "`n" | ForEach-Object { "$_`n" })
        metadata = @{}; outputs = @(); execution_count = $null
    })
    $bootstrapDef = @{ format = 'ipynb'; parts = @(@{
        path = 'notebook-content.ipynb'; payloadType = 'InlineBase64'
        payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($bootstrap | ConvertTo-Json -Depth 30)))
    }) }
    Invoke-Api -Path "workspaces/$wsId/notebooks/$($nb.id)/updateDefinition" -Method POST -Body @{ definition = $bootstrapDef } | Out-Null
    try {
        Write-Step "Running '$nbName' (takes a few minutes)..."
        $runBody = @{ executionData = @{ configuration = @{ defaultLakehouse = @{ name = $lhName; id = $lh.id; workspaceId = $wsId } } } }
        $resp = Invoke-Api -Path "workspaces/$wsId/items/$($nb.id)/jobs/instances?jobType=RunNotebook" -Method POST -Body $runBody -NoWait
        $jobUrl = @($resp.Headers['Location'])[0]
        $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
        do {
            Start-Sleep -Seconds 20
            $job = Invoke-Api -Path $jobUrl
        } while ($job.status -notin 'Completed', 'Failed', 'Cancelled', 'Deduped' -and (Get-Date) -lt $deadline)
        if ($job.status -ne 'Completed') {
            $why = if ($job.PSObject.Properties['failureReason'] -and $job.failureReason) { $job.failureReason.message } else { '' }
            throw "Notebook run ended as '$($job.status)'. $why Open '$nbName' in '$wsName' to see the output."
        }
        Write-Step 'Notebook run completed.' 'Ok'
    } finally {
        Invoke-Api -Path "workspaces/$wsId/notebooks/$($nb.id)/updateDefinition" -Method POST -Body @{ definition = $nbDef } | Out-Null
    }
}

# ----------------------------------------------------------------------------
# 5. Connection (workspace identity -> SQL endpoint)
# ----------------------------------------------------------------------------

$connPath = "$sqlServer;$lhName"
$conn = Get-ByName -Path 'connections' -Name $connName
if ($conn -and $conn.connectionDetails.path -ne $connPath) {
    throw "Connection '$connName' exists but points to '$($conn.connectionDetails.path)'. Delete it or set connectionName."
}
if (-not $conn) {
    $conn = Invoke-Api -Path 'connections' -Method POST -Body @{
        connectivityType  = 'ShareableCloud'
        displayName       = $connName
        privacyLevel      = 'Organizational'
        connectionDetails = @{ type = 'SQL'; creationMethod = 'Sql'; parameters = @(
                @{ dataType = 'Text'; name = 'server'; value = $sqlServer },
                @{ dataType = 'Text'; name = 'database'; value = $lhName }) }
        credentialDetails = @{ singleSignOnType = 'None'; connectionEncryption = 'NotEncrypted'; skipTestConnection = $false
                               credentials = @{ credentialType = 'WorkspaceIdentity' } }
    }
    Write-Step "Created connection '$connName' (workspace identity)." 'Ok'
} else {
    Write-Step "Connection '$connName' exists." 'Skip'
}

# ----------------------------------------------------------------------------
# 6. Semantic model
# ----------------------------------------------------------------------------

$builder = Join-Path $repoRoot 'src\build_artifacts.py'
$modelJson = & python $builder --kind model --server $sqlServer --database $lhName
if ($LASTEXITCODE -ne 0) { throw 'Model definition generation failed.' }
$modelDef = $modelJson | ConvertFrom-Json

$model = Get-ByName -Path "workspaces/$wsId/semanticModels" -Name $modelName
if ($model) {
    Invoke-Api -Path "workspaces/$wsId/semanticModels/$($model.id)/getDefinition?format=TMDL" -Method POST | Out-Null
    Invoke-Api -Path "workspaces/$wsId/semanticModels/$($model.id)/updateDefinition" -Method POST -Body @{ definition = $modelDef } | Out-Null
    Write-Step "Updated semantic model '$modelName'." 'Ok'
} else {
    Invoke-Api -Path "workspaces/$wsId/semanticModels" -Method POST -Body @{ displayName = $modelName; definition = $modelDef } | Out-Null
    $model = Get-ByName -Path "workspaces/$wsId/semanticModels" -Name $modelName
    Write-Step "Created semantic model '$modelName' ($($model.id))." 'Ok'
}

$references = @((Invoke-Api -Path "workspaces/$wsId/items/$($model.id)/connections").value |
    Where-Object { $_.connectionDetails.type -eq 'SQL' -and $_.connectionDetails.path -eq $connPath })
if ($references.Count -ne 1) { throw 'Expected one SQL data source reference matching the Lakehouse connection.' }
Invoke-Api -Path "workspaces/$wsId/semanticModels/$($model.id)/bindConnection" -Method POST -Body @{
    connectionBinding = @{ id = $conn.id; connectivityType = 'ShareableCloud'; connectionDetails = $references[0].connectionDetails }
} | Out-Null
$bindings = @((Invoke-Api -Path "workspaces/$wsId/items/$($model.id)/connections").value)
if (-not ($bindings | Where-Object { $_.id -eq $conn.id })) { throw 'Connection binding readback did not match the requested connection.' }
Write-Step "Bound the model to connection '$connName'." 'Ok'

Write-Step 'Syncing SQL endpoint metadata...'
try {
    Invoke-Api -Path "workspaces/$wsId/sqlEndpoints/$($sqlProps.id)/refreshMetadata" -Method POST -Body @{} | Out-Null
    Write-Step 'SQL endpoint metadata synced.' 'Ok'
} catch { Write-Step "SQL endpoint sync failed ($($_.Exception.Message)); continuing." 'Warn' }

Write-Step 'Refreshing the semantic model...'
for ($attempt = 1; $attempt -le 4; $attempt++) {
    Invoke-Api -PowerBI -Path "groups/$wsId/datasets/$($model.id)/refreshes" -Method POST -Body @{ type = 'full' } | Out-Null
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    do {
        Start-Sleep -Seconds 15
        $rf = (Invoke-Api -PowerBI -Path "groups/$wsId/datasets/$($model.id)/refreshes?`$top=1").value[0]
    } while ($rf.status -in 'Unknown', 'NotStarted', 'InProgress' -and (Get-Date) -lt $deadline)
    # A brand-new lakehouse table can take a minute to appear in the SQL endpoint.
    if ($rf.status -eq 'Completed' -or "$($rf.serviceExceptionJson)" -notmatch "key didn't match") { break }
    Write-Step "SQL endpoint not caught up yet; retrying in 60s (attempt $attempt)." 'Warn'
    Start-Sleep -Seconds 60
}
if ($rf.status -ne 'Completed') { throw "Model refresh ended as '$($rf.status)': $($rf.serviceExceptionJson)" }
Write-Step 'Model refresh completed.' 'Ok'

# ----------------------------------------------------------------------------
# 7. Report
# ----------------------------------------------------------------------------

$reportJson = & python $builder --kind report --model-id $model.id
if ($LASTEXITCODE -ne 0) { throw 'Report definition generation failed.' }
$reportDef = $reportJson | ConvertFrom-Json

$report = Get-ByName -Path "workspaces/$wsId/reports" -Name $reportName
if ($report) {
    Invoke-Api -Path "workspaces/$wsId/reports/$($report.id)/updateDefinition" -Method POST -Body @{ definition = $reportDef } | Out-Null
    Write-Step "Updated report '$reportName'." 'Ok'
} else {
    Invoke-Api -Path "workspaces/$wsId/reports" -Method POST -Body @{ displayName = $reportName; definition = $reportDef } | Out-Null
    $report = Get-ByName -Path "workspaces/$wsId/reports" -Name $reportName
    Write-Step "Created report '$reportName' ($($report.id))." 'Ok'
}

Invoke-Api -Path "workspaces/$wsId/notebooks/$($nb.id)/updateDefinition" -Method POST -Body @{ definition = $nbDef } | Out-Null

Write-Host ''
Write-Host 'Done.' -ForegroundColor Green
Write-Host "  Report : https://app.powerbi.com/groups/$wsId/reports/$($report.id)"
Write-Host "  Model  : https://app.powerbi.com/groups/$wsId/datasets/$($model.id)"
Write-Host "  The notebook runs daily at $schedTime ($schedTz) and refreshes the model when it finishes."
