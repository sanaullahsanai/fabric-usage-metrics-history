<#
.SYNOPSIS
    Deploys Usage Metrics History end to end. Safe to re-run.

.DESCRIPTION
     1. Workspace on the capacity, with a workspace identity
     2. Lakehouse (and its SQL analytics endpoint)
     3. Snapshot notebook with settings injected + daily schedule
     4. First notebook run (creates the usage_metrics_* and um_* tables)
     5. Cloud connection to the SQL endpoint using the workspace identity
     6. Semantic model cloned from Microsoft's Usage Metrics Report model,
        with its six data sources switched to the lakehouse; bound and refreshed
     7. Report cloned from Microsoft's Usage Metrics Report, bound to the model

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
$modelName   = Get-Setting 'semanticModelName' 'Usage Metrics History'
$reportName  = Get-Setting 'reportName' 'Usage Metrics History'
$connName    = Get-Setting 'connectionName' "$wsName-$lhName-SQL"
$sources     = @(Get-Setting 'sourceWorkspaces' @() | Where-Object { $_ })
$template    = Get-Setting 'templateWorkspace' ''
$retention   = [int](Get-Setting 'retentionDays' 730)
$schedTime   = [string](Get-Setting 'scheduleTime' '05:00')
$schedTz     = [string](Get-Setting 'scheduleTimeZone' 'UTC')
$expose      = [bool](Get-Setting 'exposeIdentity' $true)

if (-not $capName -and -not $capId) { throw "Set capacityName or capacityId in $ConfigPath." }
if ($retention -lt 0) { throw "retentionDays must be 0 (keep forever) or a positive number of days." }
if ($retention -gt 0 -and $retention -lt 31) { Write-Step "retentionDays=$retention keeps less than the 30 days the built-in report already has." 'Warn' }
if ($schedTime -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { throw "scheduleTime must be HH:mm (24h), not '$schedTime'." }
try { [void][TimeZoneInfo]::FindSystemTimeZoneById($schedTz) } catch { throw "scheduleTimeZone '$schedTz' is not a Windows time zone id (e.g. 'UTC', 'AUS Eastern Standard Time'). List them with: Get-TimeZone -ListAvailable" }
if (-not $template) {
    if ($sources.Count -eq 0) { throw "Set templateWorkspace (or sourceWorkspaces) so the Usage Metrics Report can be cloned." }
    $template = $sources[0]
}

$retentionText = if ($retention -eq 0) { 'forever' } else { "$retention days" }
Write-Host ''
Write-Host "=== Usage Metrics History -> '$wsName' ===" -ForegroundColor White
Write-Step "Sources: $(if ($sources.Count) { $sources -join ', ' } else { 'all accessible workspaces' }) | retention: $retentionText | daily at $schedTime ($schedTz)"

function Resolve-Workspace([string] $NameOrId) {
    if ($NameOrId -match '^[0-9a-fA-F-]{36}$') { return (Invoke-Api -Path "workspaces/$NameOrId") }
    $w = Get-ByName -Path 'workspaces' -Name $NameOrId
    if (-not $w) { throw "Workspace '$NameOrId' not found or not accessible." }
    return $w
}

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
    $ws = Invoke-Api -Path 'workspaces' -Method POST -Body @{ displayName = $wsName; capacityId = $cap.id; description = 'Usage Metrics History: daily snapshots of Power BI usage metrics.' }
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
$pyList = '[' + (($sources | ForEach-Object { ConvertTo-PyString $_ }) -join ', ') + ']'
$params = [ordered]@{
    SOURCE_WORKSPACES   = $pyList
    RETENTION_DAYS      = "$retention"
    EXPOSE_IDENTITY     = $(if ($expose) { 'True' } else { 'False' })
    SEMANTIC_MODEL_NAME = (ConvertTo-PyString $modelName)
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
    Invoke-Api -Path "workspaces/$wsId/notebooks" -Method POST -Body @{ displayName = $nbName; description = 'Daily snapshot of the Power BI Usage Metrics model(s) into the lakehouse.'; definition = $nbDef } | Out-Null
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

$tplWs = Resolve-Workspace $template
$tplModel = Get-ByName -PowerBI -Path "groups/$($tplWs.id)/datasets" -Name 'Usage Metrics Report'
$tplReport = Get-ByName -PowerBI -Path "groups/$($tplWs.id)/reports" -Name 'Usage Metrics Report'
if (-not $tplModel -or -not $tplReport) {
    throw "No 'Usage Metrics Report' in '$($tplWs.displayName)'. Open 'View usage metrics report' on any report in that workspace once, then re-run."
}
Write-Step "Template: Usage Metrics Report in '$($tplWs.displayName)'."

$partitions = [ordered]@{
    'Report views'      = 'um_report_views'
    'Report page views' = 'um_report_page_views'
    'Report load times' = 'um_report_load_times'
    'Reports'           = 'um_reports'
    'Report pages'      = 'um_report_pages'
    'Report rank'       = 'um_report_rank'
}

function Set-LakehousePartition([string] $Text, [string] $Item) {
    $nl = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = $Text -split "`r?`n"
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\tpartition .+ = m\s*$') { $start = $i; break } }
    if ($start -lt 0) { throw "No M partition found for $Item." }
    $end = $lines.Count
    for ($j = $start + 1; $j -lt $lines.Count; $j++) { if ($lines[$j] -match '^\t\S') { $end = $j; break } }
    $new = @(
        $lines[$start]
        "`t`tmode: import"
        "`t`tsource ="
        "`t`t`t`tlet"
        "`t`t`t`t    Source = Sql.Database(SqlEndpoint, LakehouseName),"
        "`t`t`t`t    Data = Source{[Schema=`"dbo`", Item=`"$Item`"]}[Data]"
        "`t`t`t`tin"
        "`t`t`t`t    Data"
        ''
    )
    $out = @()
    if ($start -gt 0) { $out += $lines[0..($start - 1)] }
    $out += $new
    if ($end -lt $lines.Count) { $out += $lines[$end..($lines.Count - 1)] }
    return ($out -join $nl)
}

$modelParts = ConvertFrom-DefinitionParts (Invoke-Api -Path "workspaces/$($tplWs.id)/semanticModels/$($tplModel.id)/getDefinition?format=TMDL" -Method POST).definition.parts
foreach ($k in @($modelParts.Keys)) { if ($k -match '(^|/)\.') { $modelParts.Remove($k) } }
foreach ($t in $partitions.Keys) {
    $key = "definition/tables/$t.tmdl"
    if (-not $modelParts.Contains($key)) { throw "Template model has no table '$t'; its layout has changed." }
    $modelParts[$key] = Set-LakehousePartition $modelParts[$key] $partitions[$t]
}
$expr = $modelParts['definition/expressions.tmdl']
$nl = if ($expr.Contains("`r`n")) { "`r`n" } else { "`n" }
foreach ($p in @(@('SqlEndpoint', $sqlServer), @('LakehouseName', $lhName))) {
    $expr = $expr.TrimEnd() + $nl + $nl +
        "expression $($p[0]) = `"$($p[1])`" meta [IsParameterQuery = true, IsParameterQueryRequired = true, Type = `"Text`"]" + $nl +
        "`tlineageTag: $([guid]::NewGuid())" + $nl + $nl +
        "`tannotation PBI_ResultType = Text" + $nl
}
$modelParts['definition/expressions.tmdl'] = $expr
$modelDef = @{ parts = @(ConvertTo-DefinitionParts $modelParts) }

$model = Get-ByName -Path "workspaces/$wsId/semanticModels" -Name $modelName
if ($model) {
    Invoke-Api -Path "workspaces/$wsId/semanticModels/$($model.id)/updateDefinition" -Method POST -Body @{ definition = $modelDef } | Out-Null
    Write-Step "Updated semantic model '$modelName'." 'Ok'
} else {
    Invoke-Api -Path "workspaces/$wsId/semanticModels" -Method POST -Body @{ displayName = $modelName; definition = $modelDef } | Out-Null
    $model = Get-ByName -Path "workspaces/$wsId/semanticModels" -Name $modelName
    Write-Step "Created semantic model '$modelName' ($($model.id))." 'Ok'
}

Invoke-Api -Path "workspaces/$wsId/semanticModels/$($model.id)/bindConnection" -Method POST -Body @{
    connectionBinding = @{ id = $conn.id; connectivityType = 'ShareableCloud'; connectionDetails = @{ type = 'SQL'; path = $connPath } }
} | Out-Null
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

$reportParts = ConvertFrom-DefinitionParts (Invoke-Api -Path "workspaces/$($tplWs.id)/reports/$($tplReport.id)/getDefinition" -Method POST).definition.parts
foreach ($k in @($reportParts.Keys)) { if ($k -match '(^|/)\.') { $reportParts.Remove($k) } }
$reportParts['definition.pbir'] = ([ordered]@{
    '$schema'        = 'https://developer.microsoft.com/json-schemas/fabric/item/report/definitionProperties/2.0.0/schema.json'
    version          = '4.0'
    datasetReference = @{ byConnection = @{
        connectionString = "Data Source=`"powerbi://api.powerbi.com/v1.0/myorg/$wsName`";initial catalog=`"$modelName`";integrated security=ClaimsToken;semanticmodelid=$($model.id)" } }
} | ConvertTo-Json -Depth 5)

# The FAQ describes the built-in 30-day window; describe the retained history instead.
$faqOld = 'The usage report is based on activity data for the last 30 days'
$faqNew = if ($retention -eq 0) { 'The usage report is based on daily snapshots of the activity data, kept with no time limit' }
          else { "The usage report is based on daily snapshots of the activity data for up to the last $retention days" }
foreach ($k in @($reportParts.Keys)) {
    if ($reportParts[$k] -is [string] -and $reportParts[$k].Contains($faqOld)) { $reportParts[$k] = $reportParts[$k].Replace($faqOld, $faqNew) }
}
$reportDef = @{ parts = @(ConvertTo-DefinitionParts $reportParts) }

$report = Get-ByName -Path "workspaces/$wsId/reports" -Name $reportName
if ($report) {
    Invoke-Api -Path "workspaces/$wsId/reports/$($report.id)/updateDefinition" -Method POST -Body @{ definition = $reportDef } | Out-Null
    Write-Step "Updated report '$reportName'." 'Ok'
} else {
    Invoke-Api -Path "workspaces/$wsId/reports" -Method POST -Body @{ displayName = $reportName; definition = $reportDef } | Out-Null
    $report = Get-ByName -Path "workspaces/$wsId/reports" -Name $reportName
    Write-Step "Created report '$reportName' ($($report.id))." 'Ok'
}

Write-Host ''
Write-Host 'Done.' -ForegroundColor Green
Write-Host "  Report : https://app.powerbi.com/groups/$wsId/reports/$($report.id)"
Write-Host "  Model  : https://app.powerbi.com/groups/$wsId/datasets/$($model.id)"
Write-Host "  The notebook runs daily at $schedTime ($schedTz) and refreshes the model when it finishes."
