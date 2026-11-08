#requires -Version 5.1

function Get-LabOrchestratorContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,
        [Parameter(Mandatory = $true)]
        [ValidateSet('SERVER', 'CLIENT')]
        [string]$Role
    )

    $rootFull = [System.IO.Path]::GetFullPath($Root)
    $roleUpper = $Role.ToUpperInvariant()
    $roleLower = $Role.ToLowerInvariant()
    $logRoot = Join-Path -Path $rootFull -ChildPath 'LOGS'

    return [pscustomobject]@{
        Root              = $rootFull
        Role              = $roleUpper
        StateDirectory    = Join-Path -Path $rootFull -ChildPath 'STATE'
        StateFile         = Join-Path -Path (Join-Path -Path $rootFull -ChildPath 'STATE') -ChildPath ('{0}-state.json' -f $roleLower)
        LogDirectory      = Join-Path -Path $logRoot -ChildPath $roleUpper
        ResumeTaskName    = ('EAUT-Lab-{0}-Resume' -f $roleUpper)
        ResumeScript      = Join-Path -Path $rootFull -ChildPath ('START-{0}.ps1' -f $roleUpper)
    }
}

function Initialize-LabOrchestratorContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Context
    )

    foreach ($path in @($Context.StateDirectory, $Context.LogDirectory)) {
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }
}

function New-LabOrchestratorState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('SERVER', 'CLIENT')]
        [string]$Role
    )

    return [pscustomobject]@{
        Version      = 1
        Role         = $Role.ToUpperInvariant()
        Checkpoint   = 'new'
        RebootCount  = 0
        LastScript   = ''
        LastExitCode = $null
        PendingReboot = $false
        LastError    = ''
        CompletedSteps = @()
        CreatedUtc   = (Get-Date).ToUniversalTime().ToString('o')
        UpdatedUtc   = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Read-LabOrchestratorState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Context
    )

    $result = [pscustomobject]@{
        Exists  = $false
        Corrupt = $false
        State   = $null
    }

    if (-not (Test-Path -LiteralPath $Context.StateFile)) {
        return $result
    }

    $result.Exists = $true
    try {
        $state = Get-Content -LiteralPath $Context.StateFile -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if (-not $state.PSObject.Properties['Checkpoint'] -or -not $state.PSObject.Properties['RebootCount']) {
            throw 'State file is missing required properties.'
        }
        $result.State = $state
    }
    catch {
        $result.Corrupt = $true
        $result.State = $null
    }

    return $result
}

function Save-LabOrchestratorState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Context,
        [Parameter(Mandatory = $true)]
        $State
    )

    Initialize-LabOrchestratorContext -Context $Context
    if (-not $State.PSObject.Properties['UpdatedUtc']) {
        $State | Add-Member -NotePropertyName UpdatedUtc -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
    }
    else {
        $State.UpdatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }

    $json = $State | ConvertTo-Json -Depth 8
    $tempPath = '{0}.tmp' -f $Context.StateFile
    Set-Content -LiteralPath $tempPath -Value $json -Encoding UTF8
    Move-Item -LiteralPath $tempPath -Destination $Context.StateFile -Force
}

function Set-LabOrchestratorCheckpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Context,
        [Parameter(Mandatory = $true)]
        $State,
        [Parameter(Mandatory = $true)]
        [string]$Checkpoint,
        [string]$LastScript,
        [Nullable[int]]$LastExitCode,
        [string]$LastError,
        [Nullable[bool]]$PendingReboot
    )

    $State.Checkpoint = $Checkpoint
    if ($PSBoundParameters.ContainsKey('LastScript')) { $State.LastScript = $LastScript }
    if ($PSBoundParameters.ContainsKey('LastExitCode')) { $State.LastExitCode = $LastExitCode }
    if ($PSBoundParameters.ContainsKey('LastError')) { $State.LastError = $LastError }
    if ($PSBoundParameters.ContainsKey('PendingReboot')) { $State.PendingReboot = $PendingReboot }

    Save-LabOrchestratorState -Context $Context -State $State
    return $State
}

function Add-LabCompletedStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Context,
        [Parameter(Mandatory = $true)]
        $State,
        [Parameter(Mandatory = $true)]
        [string]$Step
    )

    $steps = @($State.CompletedSteps)
    if ($steps -notcontains $Step) {
        $State.CompletedSteps = @($steps + $Step)
        Save-LabOrchestratorState -Context $Context -State $State
    }
    return $State
}

function Get-LabResumeTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Context
    )

    return (Get-ScheduledTask -TaskName $Context.ResumeTaskName -ErrorAction SilentlyContinue)
}

function Register-LabResumeTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Context
    )

    if (-not (Test-Path -LiteralPath $Context.ResumeScript)) {
        throw ('Resume script not found: {0}' -f $Context.ResumeScript)
    }

    $powershellExe = Join-Path -Path $env:SystemRoot -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powershellExe)) {
        throw ('Windows PowerShell executable not found: {0}' -f $powershellExe)
    }

    $arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Normal -File "{0}" -Resume -FromResumeTask' -f $Context.ResumeScript

    $existing = Get-LabResumeTask -Context $Context
    if ($existing) {
        $existingAction = @($existing.Actions) | Select-Object -First 1
        $sameAction = (
            $existingAction -and
            ([string]$existingAction.Execute -eq $powershellExe) -and
            ([string]$existingAction.Arguments -eq $arguments) -and
            ([string]$existingAction.WorkingDirectory -eq $Context.Root)
        )
        if ([string]$existing.State -in @('Running', 'Queued')) {
            if ($sameAction) {
                return $existing
            }
            throw ('Resume task {0} is currently running with a stale action. Wait for it to finish, then remove it manually before retrying.' -f $Context.ResumeTaskName)
        }
        Unregister-ScheduledTask -TaskName $Context.ResumeTaskName -Confirm:$false -ErrorAction SilentlyContinue
    }

    $action = New-ScheduledTaskAction -Execute $powershellExe -Argument $arguments -WorkingDirectory $Context.Root
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -GroupId 'BUILTIN\Administrators' -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 2)
    $description = 'EAUT lab automatic resume for {0}. Removed automatically after completion.' -f $Context.Role

    Register-ScheduledTask -TaskName $Context.ResumeTaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description $description -Force | Out-Null

    $registered = Get-LabResumeTask -Context $Context
    if (-not $registered) {
        throw ('Failed to register resume task {0}.' -f $Context.ResumeTaskName)
    }
    return $registered
}

function Unregister-LabResumeTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Context,
        [switch]$Deferred
    )

    $existing = Get-LabResumeTask -Context $Context
    if (-not $existing) {
        return $false
    }

    if ($Deferred -or [string]$existing.State -in @('Running', 'Queued')) {
        $powershellExe = Join-Path -Path $env:SystemRoot -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $taskName = $Context.ResumeTaskName.Replace("'", "''")
        $command = "Start-Sleep -Seconds 5; Unregister-ScheduledTask -TaskName '{0}' -Confirm:`$false -ErrorAction SilentlyContinue" -f $taskName
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($command))
        $startParams = @{
            FilePath     = $powershellExe
            ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-EncodedCommand', $encoded)
            WindowStyle  = 'Hidden'
            ErrorAction  = 'Stop'
        }
        Start-Process @startParams | Out-Null
        Write-LabLog -Level INFO -Message ('Resume task {0} cleanup was deferred until this process exits.' -f $Context.ResumeTaskName)
        return $true
    }

    Unregister-ScheduledTask -TaskName $Context.ResumeTaskName -Confirm:$false -ErrorAction Stop
    return $true
}

function Invoke-LabChildScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory,
        [string]$LogDirectory
    )

    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        throw ('Child script not found: {0}' -f $ScriptPath)
    }

    $powershellExe = Join-Path -Path $env:SystemRoot -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $ScriptPath
    foreach ($argument in @($ArgumentList)) {
        if ($null -ne $argument -and [string]$argument -ne '') {
            $arguments = '{0} {1}' -f $arguments, [string]$argument
        }
    }

    $previousLogDirectory = $env:EAUT_LAB_LOG_DIR
    if ($LogDirectory) {
        $env:EAUT_LAB_LOG_DIR = $LogDirectory
    }

    try {
        $startParams = @{
            FilePath     = $powershellExe
            ArgumentList = $arguments
            NoNewWindow  = $true
            Wait         = $true
            PassThru     = $true
            ErrorAction  = 'Stop'
        }
        if ($WorkingDirectory) { $startParams.WorkingDirectory = $WorkingDirectory }

        $process = Start-Process @startParams
        if ($null -eq $process.ExitCode) {
            throw ('Child process {0} did not return an exit code.' -f $ScriptPath)
        }
        return [int]$process.ExitCode
    }
    finally {
        $env:EAUT_LAB_LOG_DIR = $previousLogDirectory
    }
}

function Set-LabRebootCheckpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Context,
        [Parameter(Mandatory = $true)]
        $State,
        [Parameter(Mandatory = $true)]
        [string]$Checkpoint,
        [string]$LastScript,
        [Nullable[int]]$LastExitCode,
        [int]$MaximumReboots = 4
    )

    if ([int]$State.RebootCount -ge $MaximumReboots) {
        throw ('Reboot loop protection: {0} automatic reboots already recorded. Review the logs and state file before continuing.' -f $State.RebootCount)
    }

    $State.RebootCount = [int]$State.RebootCount + 1
    $State.Checkpoint = $Checkpoint
    $State.PendingReboot = $true
    if ($PSBoundParameters.ContainsKey('LastScript')) { $State.LastScript = $LastScript }
    if ($PSBoundParameters.ContainsKey('LastExitCode')) { $State.LastExitCode = $LastExitCode }
    Save-LabOrchestratorState -Context $Context -State $State

    [void](Register-LabResumeTask -Context $Context)
    return $State
}

Export-ModuleMember -Function *
