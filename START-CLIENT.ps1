<#
.SYNOPSIS
    One-command client deployment for the EAUT AD DS/DHCP lab.

.DESCRIPTION
    Run this script only on the Windows 10 client VM after the server reports
    SERVER IS READY FOR CLIENT DEPLOYMENT. It orchestrates client preparation,
    domain join, automatic reboot/resume, DHCP activation, lease verification,
    DNS suffix verification, and final client readiness checks.

.PARAMETER Status
    Read-only status report. Does not change configuration, state, or scheduled tasks.

.PARAMETER Verify
    Read-only final client verification.

.PARAMETER Resume
    Continue an interrupted deployment from the saved state and the actual machine state.

.PARAMETER FromResumeTask
    Internal switch used by the automatically registered logon resume task.
#>
[CmdletBinding(DefaultParameterSetName = 'Deploy')]
param(
    [Parameter(ParameterSetName = 'Status')]
    [switch]$Status,

    [Parameter(ParameterSetName = 'Verify')]
    [switch]$Verify,

    [Parameter(ParameterSetName = 'Deploy')]
    [switch]$Resume,

    [Parameter(ParameterSetName = 'Deploy')]
    [switch]$FromResumeTask
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$modulePath = Join-Path -Path $scriptRoot -ChildPath 'LIB\LabCommon.psm1'
$orchestratorPath = Join-Path -Path $scriptRoot -ChildPath 'LIB\LabOrchestrator.psm1'

foreach ($requiredPath in @($modulePath, $orchestratorPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        Write-Host ('ERROR: Required module not found: {0}. Copy the entire EAUT-AD-DHCP-LAB folder.' -f $requiredPath) -ForegroundColor Red
        exit 2
    }
}

Import-Module -Name $modulePath -Force
Import-Module -Name $orchestratorPath -Force

$context = Get-LabOrchestratorContext -Root $scriptRoot -Role 'CLIENT'
Initialize-LabOrchestratorContext -Context $context
$env:EAUT_LAB_ROLE = 'CLIENT'
$env:EAUT_LAB_LOG_DIR = $context.LogDirectory

function Write-LabResultBanner {
    param(
        [string]$Message,
        [bool]$Success
    )

    $color = if ($Success) { 'Green' } else { 'Red' }
    $level = if ($Success) { 'SUCCESS' } else { 'ERROR' }
    $line = '=' * 64
    Write-Host ''
    Write-Host $line -ForegroundColor $color
    Write-Host $Message -ForegroundColor $color
    Write-Host $line -ForegroundColor $color
    Write-LabLog -Level $level -Message $Message
}

function Get-LabClientActualState {
    param(
        [Parameter(Mandatory = $true)]
        $Config
    )

    $server = $Config.Server
    $client = $Config.Client
    $domain = $Config.Domain
    $dhcp = $Config.Dhcp
    $scopeStart = ConvertTo-LabUInt32 -IPAddress $dhcp.StartRange
    $scopeEnd = ConvertTo-LabUInt32 -IPAddress $dhcp.EndRange

    $state = Get-LabComputerState
    $adapter = Get-LabNetworkAdapter -MacAddress $client.MacAddress -KnownIPs @($client.StaticIPAddress, $client.BaselineIPAddress)
    $interface = Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop
    $addresses = @(Get-LabInterfaceAddresses -InterfaceIndex $adapter.ifIndex)
    $lease = @($addresses | Where-Object {
            $number = ConvertTo-LabUInt32 -IPAddress $_.IPAddress
            $number -ge $scopeStart -and $number -le $scopeEnd -and $_.PrefixOrigin -eq 'Dhcp'
        }) | Select-Object -First 1
    $staticAddress = @($addresses | Where-Object { $_.IPAddress -eq $client.StaticIPAddress })
    $dnsServers = @(Get-LabDnsClientServers -InterfaceIndex $adapter.ifIndex)
    $suffix = Get-LabConnectionDnsSuffix -InterfaceIndex $adapter.ifIndex
    $routes = @(Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
    $secure = $false
    try { $secure = Test-ComputerSecureChannel -ErrorAction Stop } catch { $secure = $false }

    return [pscustomobject]@{
        ComputerState       = $state
        Adapter             = $adapter
        NameOk              = ($state.Name -eq $client.Name)
        IsDomainJoined      = ([bool]$state.PartOfDomain -and $state.Domain -eq $domain.DnsName)
        Domain              = $state.Domain
        SecureChannel       = [bool]$secure
        Interface           = $interface
        Addresses           = $addresses
        Lease               = $lease
        StaticAddress       = $staticAddress
        DhcpServer          = Get-LabDhcpServerAddress -InterfaceIndex $adapter.ifIndex
        DnsServers          = $dnsServers
        DnsSuffix           = $suffix
        NoDefaultRoute      = ($routes.Count -eq 0)
        StaticIpOk          = (@($addresses | Where-Object { $_.IPAddress -eq $client.StaticIPAddress -and $_.PrefixLength -eq $client.PrefixLength -and $_.PrefixOrigin -ne 'Dhcp' }).Count -eq 1)
        StaticDnsOk         = ((($dnsServers | Sort-Object) -join ',') -eq ((@($client.DnsServers) | Sort-Object) -join ','))
        LeaseOk             = [bool]($interface.Dhcp -eq 'Enabled' -and $lease -and $staticAddress.Count -eq 0 -and $lease.IPAddress -ne $client.StaticIPAddress)
        DnsFromDhcpOk       = ((($dnsServers | Sort-Object) -join ',') -eq ((@($server.DnsServers) | Sort-Object) -join ','))
        SuffixOk            = ($suffix -eq $domain.DnsName)
    }
}

function Invoke-LabClientReboot {
    param(
        [Parameter(Mandatory = $true)]
        $Context,
        [Parameter(Mandatory = $true)]
        $State,
        [Parameter(Mandatory = $true)]
        [string]$Checkpoint,
        [string]$LastScript,
        [Nullable[int]]$LastExitCode
    )

    $checkpointParams = @{
        Context    = $Context
        State      = $State
        Checkpoint = $Checkpoint
    }
    if ($PSBoundParameters.ContainsKey('LastScript')) { $checkpointParams.LastScript = $LastScript }
    if ($PSBoundParameters.ContainsKey('LastExitCode')) { $checkpointParams.LastExitCode = $LastExitCode }
    [void](Set-LabRebootCheckpoint @checkpointParams)

    Write-LabLog -Level WARN -Message ('Automatic reboot {0} requested at checkpoint {1}. The resume task will continue after an administrator logs on.' -f $State.RebootCount, $Checkpoint)
    Write-LabLog -Level WARN -Message 'Do not close the VMware console permanently. The resume task needs an Administrator logon after reboot.'
    Restart-Computer -Force -ErrorAction Stop
    exit 0
}

function Invoke-LabClientFinalChecks {
    param(
        [Parameter(Mandatory = $true)]
        $Config
    )

    Clear-LabChecks
    $server = $Config.Server
    $client = $Config.Client
    $domain = $Config.Domain
    $dhcp = $Config.Dhcp
    $serverFqdn = '{0}.{1}' -f $server.Name, $domain.DnsName
    $scopeStart = ConvertTo-LabUInt32 -IPAddress $dhcp.StartRange
    $scopeEnd = ConvertTo-LabUInt32 -IPAddress $dhcp.EndRange

    $state = Get-LabComputerState
    Add-LabCheck -Name 'Client Name' -Status ($(if ($state.Name -eq $client.Name) { 'PASS' } else { 'FAIL' })) -Detail ('current={0}, expected={1}' -f $state.Name, $client.Name)

    $domainOk = ($state.PartOfDomain -and $state.Domain -eq $domain.DnsName)
    Add-LabCheck -Name 'Domain Membership' -Status ($(if ($domainOk) { 'PASS' } else { 'FAIL' })) -Detail ('Domain={0}, PartOfDomain={1}' -f $state.Domain, $state.PartOfDomain)

    $secure = $false
    try { $secure = Test-ComputerSecureChannel -ErrorAction Stop } catch { $secure = $false }
    Add-LabCheck -Name 'Secure Channel' -Status ($(if ($secure) { 'PASS' } else { 'FAIL' })) -Detail ($(if ($secure) { 'Valid' } else { 'Invalid' }))

    $adapter = Get-LabNetworkAdapter -MacAddress $client.MacAddress -KnownIPs @($client.StaticIPAddress, $client.BaselineIPAddress)
    $interface = Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop
    $addresses = @(Get-LabInterfaceAddresses -InterfaceIndex $adapter.ifIndex)
    $lease = @($addresses | Where-Object {
            $number = ConvertTo-LabUInt32 -IPAddress $_.IPAddress
            $number -ge $scopeStart -and $number -le $scopeEnd -and $_.PrefixOrigin -eq 'Dhcp'
        }) | Select-Object -First 1
    $staticAddress = @($addresses | Where-Object { $_.IPAddress -eq $client.StaticIPAddress })

    Add-LabCheck -Name 'DHCP Client' -Status ($(if ($interface.Dhcp -eq 'Enabled') { 'PASS' } else { 'FAIL' })) -Detail $interface.Dhcp.ToString()
    Add-LabCheck -Name 'DHCP Lease' -Status ($(if ($lease) { 'PASS' } else { 'FAIL' })) -Detail ($(if ($lease) { '{0}/{1} origin={2}' -f $lease.IPAddress, $lease.PrefixLength, $lease.PrefixOrigin } else { 'no in-scope DHCP lease' }))

    $dhcpServer = Get-LabDhcpServerAddress -InterfaceIndex $adapter.ifIndex
    Add-LabCheck -Name 'DHCP Server Identity' -Status ($(if ($dhcpServer -eq $server.IPAddress) { 'PASS' } else { 'FAIL' })) -Detail ('DHCP server={0}, expected={1}' -f $dhcpServer, $server.IPAddress)

    $dnsNow = @(Get-LabDnsClientServers -InterfaceIndex $adapter.ifIndex)
    Add-LabCheck -Name 'DNS Server' -Status ($(if ((($dnsNow | Sort-Object) -join ',') -eq ((@($server.DnsServers) | Sort-Object) -join ',')) { 'PASS' } else { 'FAIL' })) -Detail ($dnsNow -join ', ')

    $suffix = Get-LabConnectionDnsSuffix -InterfaceIndex $adapter.ifIndex
    $suffixOk = Wait-LabCondition -Condition {
        $current = Get-LabConnectionDnsSuffix -InterfaceIndex $adapter.ifIndex
        return ($current -eq $domain.DnsName)
    } -TimeoutSeconds 30 -IntervalSeconds 2 -Description 'DHCP DNS suffix'
    if ($suffixOk) { $suffix = $domain.DnsName }
    Add-LabCheck -Name 'DNS Suffix' -Status ($(if ($suffixOk) { 'PASS' } else { 'FAIL' })) -Detail ('connection suffix={0}, expected={1}' -f $suffix, $domain.DnsName)

    $srvOk = $false
    $aRecordOk = $false
    $portsOk = $false
    $srvDetail = ''
    try {
        $srvAnswers = @(Resolve-DnsName -Name ('_ldap._tcp.dc._msdcs.{0}' -f $domain.DnsName) -Type SRV -DnsOnly -ErrorAction Stop)
        $srvTargets = @($srvAnswers | Where-Object { $_.NameTarget } | ForEach-Object { $_.NameTarget.TrimEnd('.').ToLowerInvariant() })
        $srvOk = @($srvTargets | Where-Object { $_ -eq $serverFqdn.ToLowerInvariant() }).Count -gt 0
        $srvDetail = $srvTargets -join ', '
    }
    catch {
        $srvDetail = $_.Exception.Message
    }
    try {
        $aRecord = @(Resolve-DnsName -Name $serverFqdn -Type A -DnsOnly -ErrorAction Stop | Where-Object { $_.IPAddress })
        $aRecordOk = @($aRecord | Where-Object { $_.IPAddress -eq $server.IPAddress }).Count -gt 0
    }
    catch {
    }
    $portResults = @{}
    foreach ($port in @(53, 88, 389, 445, 135)) {
        $portResults[$port] = Test-LabTcpPort -ComputerName $server.IPAddress -Port $port
    }
    $portsOk = @($portResults.Values | Where-Object { $_ -eq $false }).Count -eq 0
    $dcOk = ($srvOk -and $aRecordOk -and $portsOk)
    $dcDetail = 'SRV={0}; A={1}; ports={2}; SRV targets={3}' -f $srvOk, $aRecordOk, (($portResults.Keys | Sort-Object | ForEach-Object { '{0}={1}' -f $_, $portResults[$_] }) -join ', '), $srvDetail
    Add-LabCheck -Name 'DC Connectivity' -Status ($(if ($dcOk) { 'PASS' } else { 'FAIL' })) -Detail $dcDetail

    $routes = @(Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
    Add-LabCheck -Name 'No Default Gateway' -Status ($(if ($routes.Count -eq 0) { 'PASS' } else { 'FAIL' })) -Detail ('default routes={0}' -f $routes.Count)
    Add-LabCheck -Name 'Temporary Static Address Removed' -Status ($(if ($staticAddress.Count -eq 0) { 'PASS' } else { 'FAIL' })) -Detail ($(if ($staticAddress.Count -eq 0) { '{0} is absent' -f $client.StaticIPAddress } else { '{0} is still configured' -f $client.StaticIPAddress }))

    return (Write-LabCheckSummary)
}

function Show-LabClientStatus {
    param(
        [Parameter(Mandatory = $true)]
        $Config,
        [Parameter(Mandatory = $true)]
        $Context,
        $State
    )

    Write-LabLog -Level STEP -Message '=== CLIENT STATUS (read-only) ==='
    if ($State) {
        Write-LabLog -Level INFO -Message ('State file : {0}' -f $Context.StateFile)
        Write-LabLog -Level INFO -Message ('Checkpoint : {0}' -f $State.Checkpoint)
        Write-LabLog -Level INFO -Message ('RebootCount: {0}' -f $State.RebootCount)
        Write-LabLog -Level INFO -Message ('LastScript : {0} (exit {1})' -f $State.LastScript, $State.LastExitCode)
    }
    else {
        Write-LabLog -Level INFO -Message ('State file : not found ({0})' -f $Context.StateFile)
    }

    $actual = Get-LabClientActualState -Config $Config
    Write-LabLog -Level INFO -Message ('Computer   : {0} | domain {1} | joined={2} | secure={3}' -f $actual.ComputerState.Name, $actual.Domain, $actual.IsDomainJoined, $actual.SecureChannel)
    Write-LabLog -Level INFO -Message ('Network    : IPv4={0} | DHCP={1} | DNS={2} | suffix={3}' -f (($actual.Addresses | ForEach-Object { '{0}/{1}' -f $_.IPAddress, $_.PrefixLength }) -join ', '), $actual.Interface.Dhcp, ($actual.DnsServers -join ', '), $actual.DnsSuffix)
    Write-LabLog -Level INFO -Message ('DHCP       : server={0} | lease={1} | inScope={2}' -f $actual.DhcpServer, ($(if ($actual.Lease) { $actual.Lease.IPAddress } else { 'none' })), [bool]$actual.Lease)

    $task = Get-LabResumeTask -Context $Context
    if ($task) {
        Write-LabLog -Level INFO -Message ('Resume task: {0} | state {1}' -f $task.TaskName, $task.State)
    }
    else {
        Write-LabLog -Level INFO -Message 'Resume task: not registered'
    }

    if ($actual.IsDomainJoined -and $actual.SecureChannel -and $actual.LeaseOk -and $actual.DnsFromDhcpOk -and $actual.SuffixOk -and $actual.NoDefaultRoute) {
        Write-LabResultBanner -Message 'CLIENT STATUS: READY' -Success $true
    }
    else {
        Write-LabResultBanner -Message 'CLIENT STATUS: INCOMPLETE' -Success $false
    }
}

$readOnlyMode = $false

try {
    Assert-LabAdministrator
    Assert-LabPowerShell51
    $config = Import-LabConfig -ScriptRoot $scriptRoot
    Start-LabSession -ScriptName 'START-CLIENT' -LogDirectory $config.Paths.LogDirectory

    $server = $config.Server
    $client = $config.Client
    $domain = $config.Domain
    $mode = $PSCmdlet.ParameterSetName

    Write-LabLog -Level STEP -Message ('=== START-CLIENT - mode {0} ===' -f $mode)
    if ($FromResumeTask) {
        Write-LabLog -Level INFO -Message 'Running from the automatic logon resume task.'
    }

    $readOnlyMode = ($mode -in @('Status', 'Verify'))
    $stateRead = Read-LabOrchestratorState -Context $context
    $state = $stateRead.State

    if ($stateRead.Corrupt) {
        Write-LabLog -Level WARN -Message ('State file is unreadable: {0}. Actual machine state will drive deployment/resume.' -f $context.StateFile)
    }
    if ($stateRead.Exists -and $state -and [string]$state.Role -ne 'CLIENT') {
        Write-LabLog -Level WARN -Message ('State file belongs to role {0}, not CLIENT.' -f $state.Role)
        $state = $null
    }

    if ($mode -eq 'Status') {
        Show-LabClientStatus -Config $config -Context $context -State $state
        exit 0
    }

    if (-not $readOnlyMode) {
        if ($stateRead.Corrupt) {
            $corruptBackup = '{0}.corrupt_{1}.json' -f $context.StateFile, (Get-Date -Format 'yyyyMMdd_HHmmss')
            try { Copy-Item -LiteralPath $context.StateFile -Destination $corruptBackup -Force } catch { }
            Write-LabLog -Level WARN -Message ('Corrupt state backup: {0}' -f $corruptBackup)
        }
        if (-not $state) {
            $state = New-LabOrchestratorState -Role 'CLIENT'
            Save-LabOrchestratorState -Context $context -State $state
        }
    }

    $actual = Get-LabClientActualState -Config $config

    if ($mode -eq 'Verify') {
        if (-not $actual.IsDomainJoined -or -not $actual.SecureChannel) {
            Add-LabCheck -Name 'Domain Membership' -Status 'FAIL' -Detail 'The client is not domain-joined with a valid secure channel.'
            [void](Write-LabCheckSummary)
            Write-LabResultBanner -Message 'CLIENT VERIFICATION FAILED' -Success $false
            exit 2
        }
        $result = Invoke-LabClientFinalChecks -Config $config
        if ($result -eq 'PASS') {
            Write-LabResultBanner -Message 'LAB DEPLOYMENT SUCCESSFUL' -Success $true
            exit 0
        }
        Write-LabResultBanner -Message 'CLIENT VERIFICATION FAILED' -Success $false
        exit 2
    }

    if ($state.Checkpoint -eq 'complete') {
        $state.RebootCount = 0
        $state.Checkpoint = 'revalidating'
        Save-LabOrchestratorState -Context $context -State $state
    }

    $pending = Get-LabPendingReboot
    if ($pending.Pending) {
        foreach ($reason in $pending.Reasons) {
            Write-LabLog -Level WARN -Message ('Pending reboot reason: {0}' -f $reason)
        }
        Invoke-LabClientReboot -Context $context -State $state -Checkpoint 'pending-reboot' -LastScript 'pending-reboot' -LastExitCode 3
    }

    if ($actual.IsDomainJoined -and -not $actual.SecureChannel) {
        throw ('The client is joined to {0}, but the machine secure channel is invalid. Do not unjoin automatically. Repair or rejoin the client, then use -Resume.' -f $domain.DnsName)
    }

    if ($actual.IsDomainJoined -and -not $actual.NameOk) {
        throw ('The client is joined to {0}, but its computer name is {1}; expected {2}. No automatic rename or unjoin was performed.' -f $domain.DnsName, $actual.ComputerState.Name, $client.Name)
    }

    if (-not $actual.IsDomainJoined) {
        if ($actual.ComputerState.PartOfDomain -and $actual.Domain -ne $domain.DnsName) {
            throw ('The client is joined to unexpected domain {0}. No automatic unjoin was performed.' -f $actual.Domain)
        }

        if (-not $actual.NameOk -or -not $actual.StaticIpOk -or -not $actual.StaticDnsOk -or -not $actual.NoDefaultRoute) {
            Write-LabLog -Level STEP -Message 'Preparing client name, temporary static IPv4, and DNS.'
            [void](Set-LabOrchestratorCheckpoint -Context $context -State $state -Checkpoint 'network-preparing')
            $exitCode = Invoke-LabChildScript -ScriptPath (Join-Path $context.Root 'CLIENT\01-Client-Prepare.ps1') -WorkingDirectory $context.Root -LogDirectory $context.LogDirectory
            if ($exitCode -eq 3) {
                [void](Add-LabCompletedStep -Context $context -State $state -Step 'network-prepared')
                Invoke-LabClientReboot -Context $context -State $state -Checkpoint 'network-reboot' -LastScript '01-Client-Prepare' -LastExitCode $exitCode
            }
            if ($exitCode -ne 0) {
                throw ('01-Client-Prepare.ps1 failed with exit code {0}.' -f $exitCode)
            }
            [void](Add-LabCompletedStep -Context $context -State $state -Step 'network-prepared')
        }
        else {
            Write-LabLog -Level INFO -Message 'Client name, temporary static IPv4, DNS, and default route are already correct; 01 is skipped.'
        }

        $actual = Get-LabClientActualState -Config $config
        $pending = Get-LabPendingReboot
        if ($pending.Pending) {
            Invoke-LabClientReboot -Context $context -State $state -Checkpoint 'network-reboot' -LastScript 'pending-reboot' -LastExitCode 3
        }
        if (-not $actual.NameOk -or -not $actual.StaticIpOk -or -not $actual.StaticDnsOk -or -not $actual.NoDefaultRoute) {
            throw 'Client preparation did not reach the temporary static target state.'
        }

        Write-LabLog -Level STEP -Message 'Joining the client to the domain.'
        [void](Set-LabOrchestratorCheckpoint -Context $context -State $state -Checkpoint 'joining-domain')
        $exitCode = Invoke-LabChildScript -ScriptPath (Join-Path $context.Root 'CLIENT\02-Join-Domain.ps1') -WorkingDirectory $context.Root -LogDirectory $context.LogDirectory
        if ($exitCode -eq 3) {
            [void](Add-LabCompletedStep -Context $context -State $state -Step 'domain-joined')
            Invoke-LabClientReboot -Context $context -State $state -Checkpoint 'domain-join-reboot' -LastScript '02-Join-Domain' -LastExitCode $exitCode
        }
        if ($exitCode -ne 0) {
            throw ('02-Join-Domain.ps1 failed with exit code {0}.' -f $exitCode)
        }
        [void](Add-LabCompletedStep -Context $context -State $state -Step 'domain-joined')

        $actual = Get-LabClientActualState -Config $config
        if (-not $actual.IsDomainJoined) {
            $pendingAfterJoin = Get-LabPendingReboot
            if ($pendingAfterJoin.Pending) {
                Invoke-LabClientReboot -Context $context -State $state -Checkpoint 'domain-join-reboot' -LastScript '02-Join-Domain' -LastExitCode 3
            }
            throw '02-Join-Domain.ps1 returned success, but the client is not visible as domain-joined.'
        }
    }
    else {
        Write-LabLog -Level INFO -Message ('Client is already joined to {0} with a valid secure channel; 01/02 are skipped.' -f $domain.DnsName)
    }

    if (-not $actual.SecureChannel) {
        throw 'The client domain join is not backed by a valid secure channel.'
    }

    if (-not $actual.LeaseOk -or -not $actual.DnsFromDhcpOk -or -not $actual.SuffixOk -or -not $actual.NoDefaultRoute) {
        Write-LabLog -Level STEP -Message 'Enabling DHCP, requesting a lease, and applying DHCP DNS options.'
        [void](Set-LabOrchestratorCheckpoint -Context $context -State $state -Checkpoint 'dhcp-configuring')
        $exitCode = Invoke-LabChildScript -ScriptPath (Join-Path $context.Root 'CLIENT\03-Configure-DHCP.ps1') -WorkingDirectory $context.Root -LogDirectory $context.LogDirectory
        if ($exitCode -eq 3) {
            Invoke-LabClientReboot -Context $context -State $state -Checkpoint 'dhcp-reboot' -LastScript '03-Configure-DHCP' -LastExitCode $exitCode
        }
        if ($exitCode -ne 0) {
            throw ('03-Configure-DHCP.ps1 failed with exit code {0}.' -f $exitCode)
        }
        [void](Add-LabCompletedStep -Context $context -State $state -Step 'dhcp-configured')
    }
    else {
        Write-LabLog -Level INFO -Message 'DHCP client, lease, DNS, suffix, and route are already correct; 03 is skipped.'
    }

    [void](Set-LabOrchestratorCheckpoint -Context $context -State $state -Checkpoint 'verifying')
    $result = Invoke-LabClientFinalChecks -Config $config
    $statistics = Get-LabCheckStatistics
    Write-LabLog -Level INFO -Message ('Final counts: PASS={0} WARN={1} FAIL={2}' -f $statistics.Pass, $statistics.Warn, $statistics.Fail)

    if ($result -ne 'PASS' -or $statistics.Warn -gt 0 -or $statistics.Fail -gt 0) {
        throw 'Client final verification did not pass cleanly. Review the failed/warning checks and logs.'
    }

    $state.Checkpoint = 'complete'
    $state.PendingReboot = $false
    $state.LastError = ''
    $state.LastExitCode = 0
    $state.LastScript = 'START-CLIENT'
    Save-LabOrchestratorState -Context $context -State $state
    try { Unregister-LabResumeTask -Context $context | Out-Null } catch { }

    Write-LabResultBanner -Message 'LAB DEPLOYMENT SUCCESSFUL' -Success $true
    exit 0
}
catch {
    $message = $_.Exception.Message
    try {
        Write-LabLog -Level ERROR -Message ('FATAL: {0}' -f $message)
    }
    catch {
        Write-Host ('FATAL: {0}' -f $message) -ForegroundColor Red
    }

    if ($state -and -not $readOnlyMode) {
        try {
            $state.LastError = $message
            $state.PendingReboot = $false
            Save-LabOrchestratorState -Context $context -State $state
        }
        catch {
        }
    }

    if (-not $readOnlyMode) {
        try { Unregister-LabResumeTask -Context $context | Out-Null } catch { }
    }
    Write-LabResultBanner -Message 'CLIENT DEPLOYMENT FAILED' -Success $false
    exit 2
}
