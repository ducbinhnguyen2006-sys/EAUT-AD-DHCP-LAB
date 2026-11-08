<#
.SYNOPSIS
    One-command server deployment for the EAUT AD DS/DNS/DHCP lab.

.DESCRIPTION
    Run this script only on the Windows Server VM. It orchestrates server preparation,
    AD DS/DNS promotion, automatic reboot/resume, DNS client enforcement, DHCP
    installation/authorization, scope configuration, and final verification.

.PARAMETER Status
    Read-only status report. Does not change configuration, state, or scheduled tasks.

.PARAMETER Verify
    Read-only final server readiness verification.

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

$context = Get-LabOrchestratorContext -Root $scriptRoot -Role 'SERVER'
Initialize-LabOrchestratorContext -Context $context
$env:EAUT_LAB_ROLE = 'SERVER'
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

function Get-LabServerActualState {
    param(
        [Parameter(Mandatory = $true)]
        $Config
    )

    $server = $Config.Server
    $domain = $Config.Domain
    $state = Get-LabComputerState
    $adapter = Get-LabNetworkAdapter -MacAddress $server.MacAddress -KnownIPs @($server.IPAddress, $server.BaselineIPAddress)
    $addresses = @(Get-LabInterfaceAddresses -InterfaceIndex $adapter.ifIndex)
    $targetAddress = @($addresses | Where-Object { $_.IPAddress -eq $server.IPAddress -and $_.PrefixLength -eq $server.PrefixLength })
    $unexpectedAddresses = @($addresses | Where-Object {
            $_.IPAddress -ne $server.IPAddress -and
            $_.PrefixOrigin -ne 'WellKnown' -and
            -not $_.IPAddress.StartsWith('169.254.')
        })
    $dnsServers = @(Get-LabDnsClientServers -InterfaceIndex $adapter.ifIndex)
    $expectedDns = @($server.DnsServers)
    $routes = @(Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)

    $adDs = Get-LabAdDsInstallState
    $adDsRoleInstalled = $false
    $dhcpRoleInstalled = $false
    try {
        $adDsRoleInstalled = ((Get-WindowsFeature -Name AD-Domain-Services).InstallState.ToString() -eq 'Installed')
    }
    catch {
    }
    try {
        $dhcpRoleInstalled = ((Get-WindowsFeature -Name DHCP).InstallState.ToString() -eq 'Installed')
    }
    catch {
    }

    $isDcRole = ($state.PartOfDomain -and $state.DomainRole -ge 4)
    $dcOperational = $false
    $adDomain = $null
    if ($isDcRole) {
        try {
            Import-LabRequiredModule -Name ActiveDirectory -PrerequisiteMessage 'A domain controller should expose the ActiveDirectory module.'
            $adDomain = Get-ADDomain -ErrorAction Stop
            $dcOperational = ($adDomain.DNSRoot -eq $domain.DnsName)
        }
        catch {
            $dcOperational = $false
        }
    }

    $promotionEvidence = (
        ($adDs.NtdsServicePresent -and $adDs.NtdsStartType -ne 'Disabled') -or
        $adDs.NtdsDatabasePresent -or
        $adDs.ProductType -eq 'LanmanNT'
    )

    return [pscustomobject]@{
        ComputerState       = $state
        Adapter             = $adapter
        NameOk              = ($state.Name -eq $server.Name)
        PartOfDomain        = [bool]$state.PartOfDomain
        DomainRole          = [int]$state.DomainRole
        IsDcRole            = [bool]$isDcRole
        DcOperational       = [bool]$dcOperational
        AdDomain            = $adDomain
        IpOk                = ($targetAddress.Count -eq 1 -and $unexpectedAddresses.Count -eq 0)
        DnsOk               = ((($dnsServers | Sort-Object) -join ',') -eq (($expectedDns | Sort-Object) -join ','))
        DnsServers          = $dnsServers
        NoDefaultRoute      = ($routes.Count -eq 0)
        Addresses           = $addresses
        AdDs                = $adDs
        AdDsRoleInstalled   = $adDsRoleInstalled
        DhcpRoleInstalled   = $dhcpRoleInstalled
        PromotionEvidence   = [bool]$promotionEvidence
    }
}

function Get-LabServerDhcpStatus {
    param(
        [Parameter(Mandatory = $true)]
        $Config
    )

    $server = $Config.Server
    $dhcp = $Config.Dhcp
    $domain = $Config.Domain
    $serverFqdn = '{0}.{1}' -f $server.Name, $domain.DnsName
    $scopeId = Get-LabScopeId -IPAddress $dhcp.StartRange -PrefixLength $server.PrefixLength

    $installed = $false
    try {
        $installed = ((Get-WindowsFeature -Name DHCP).InstallState.ToString() -eq 'Installed')
    }
    catch {
    }

    $serviceRunning = $false
    $authorized = $false
    $authorizedName = ''
    $scopeOk = $false
    $optionsOk = $false
    $bindingOk = $false
    $serverRouterOptionCount = 0
    $scope = $null

    $service = Get-Service -Name DHCPServer -ErrorAction SilentlyContinue
    if ($service) {
        $serviceRunning = ($service.Status -eq 'Running')
    }

    if ($installed) {
        try {
            Import-LabRequiredModule -Name DhcpServer -PrerequisiteMessage 'DHCP management tools are missing.'
            $entries = @(Get-DhcpServerInDC -ErrorAction Stop)
            $entry = @($entries | Where-Object { ([string]$_.IPAddress) -eq $server.IPAddress }) | Select-Object -First 1
            if ($entry) {
                $authorized = $true
                $authorizedName = [string]$entry.DnsName
            }

            $scope = Get-DhcpServerv4Scope -ScopeId $scopeId -ErrorAction SilentlyContinue
            if ($scope) {
                $scopeOk = (
                    ([string]$scope.Name -eq $dhcp.ScopeName) -and
                    ([string]$scope.StartRange -eq $dhcp.StartRange) -and
                    ([string]$scope.EndRange -eq $dhcp.EndRange) -and
                    ([string]$scope.SubnetMask -eq $server.SubnetMask) -and
                    ($scope.State -eq 'Active') -and
                    ([math]::Abs($scope.LeaseDuration.TotalDays - $dhcp.LeaseDays) -lt 0.01)
                )

                $options = @(Get-DhcpServerv4OptionValue -ScopeId $scopeId -ErrorAction SilentlyContinue)
                $dnsOption = @($options | Where-Object { $_.OptionId -eq 6 }) | Select-Object -First 1
                $domainOption = @($options | Where-Object { $_.OptionId -eq 15 }) | Select-Object -First 1
                $routerOption = @($options | Where-Object { $_.OptionId -eq 3 })
                $serverRouterOption = @(Get-DhcpServerv4OptionValue -OptionId 3 -ErrorAction SilentlyContinue | Where-Object { $_.OptionId -eq 3 })
                $serverRouterOptionCount = $serverRouterOption.Count
                $actualDns = @()
                if ($dnsOption) { $actualDns = @($dnsOption.Value | ForEach-Object { [string]$_ }) }
                $actualDomain = ''
                if ($domainOption) { $actualDomain = [string]$domainOption.Value }
                $optionsOk = (
                    ((($actualDns | Sort-Object) -join ',') -eq ((@($dhcp.DnsServers) | Sort-Object) -join ',')) -and
                    ($actualDomain -eq $dhcp.DnsDomain) -and
                    ($routerOption.Count -eq 0) -and
                    ($serverRouterOptionCount -eq 0)
                )
            }

            $binding = @(Get-DhcpServerv4Binding -ErrorAction SilentlyContinue | Where-Object {
                    ([string]$_.IPAddress) -eq $server.IPAddress -and $_.BindingState -eq $true
                })
            $bindingOk = ($binding.Count -gt 0)
        }
        catch {
        }
    }

    return [pscustomobject]@{
        Installed         = [bool]$installed
        ServiceRunning    = [bool]$serviceRunning
        Authorized        = [bool]$authorized
        AuthorizedName    = $authorizedName
        ExpectedName      = $serverFqdn
        Scope             = $scope
        ScopeId           = $scopeId
        ScopeOk           = [bool]$scopeOk
        OptionsOk         = [bool]$optionsOk
        ServerRouterOptions = [int]$serverRouterOptionCount
        BindingOk         = [bool]$bindingOk
        Ready             = [bool]($installed -and $serviceRunning -and $authorized -and $scopeOk -and $optionsOk -and $bindingOk)
    }
}

function Invoke-LabServerReboot {
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

function Invoke-LabServerFinalChecks {
    param(
        [Parameter(Mandatory = $true)]
        $Config
    )

    Clear-LabChecks
    $server = $Config.Server
    $domain = $Config.Domain
    $dhcp = $Config.Dhcp
    $serverFqdn = '{0}.{1}' -f $server.Name, $domain.DnsName
    $scopeId = Get-LabScopeId -IPAddress $dhcp.StartRange -PrefixLength $server.PrefixLength

    $state = Get-LabComputerState
    Add-LabCheck -Name 'Server Name' -Status ($(if ($state.Name -eq $server.Name) { 'PASS' } else { 'FAIL' })) -Detail ('current={0}, expected={1}' -f $state.Name, $server.Name)

    $adapter = Get-LabNetworkAdapter -MacAddress $server.MacAddress -KnownIPs @($server.IPAddress, $server.BaselineIPAddress)
    $addresses = @(Get-LabInterfaceAddresses -InterfaceIndex $adapter.ifIndex)
    $target = @($addresses | Where-Object { $_.IPAddress -eq $server.IPAddress -and $_.PrefixLength -eq $server.PrefixLength })
    $unexpected = @($addresses | Where-Object {
            $_.IPAddress -ne $server.IPAddress -and
            $_.PrefixOrigin -ne 'WellKnown' -and
            -not $_.IPAddress.StartsWith('169.254.')
        })
    $dnsNow = @(Get-LabDnsClientServers -InterfaceIndex $adapter.ifIndex)
    $dnsExpected = @($server.DnsServers)
    $routes = @(Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
    $networkOk = (
        $target.Count -eq 1 -and
        $unexpected.Count -eq 0 -and
        ((($dnsNow | Sort-Object) -join ',') -eq (($dnsExpected | Sort-Object) -join ',')) -and
        $routes.Count -eq 0
    )
    Add-LabCheck -Name 'Network Configuration' -Status ($(if ($networkOk) { 'PASS' } else { 'FAIL' })) -Detail ('IPv4={0}; DNS={1}; defaultRoutes={2}' -f (($addresses | ForEach-Object { '{0}/{1}' -f $_.IPAddress, $_.PrefixLength }) -join ', '), ($dnsNow -join ', '), $routes.Count)

    try {
        $addsFeature = Get-WindowsFeature -Name AD-Domain-Services -ErrorAction Stop
        $addsOk = ($addsFeature.InstallState.ToString() -eq 'Installed')
    }
    catch {
        $addsOk = $false
    }
    Add-LabCheck -Name 'AD DS Role' -Status ($(if ($addsOk) { 'PASS' } else { 'FAIL' })) -Detail 'AD-Domain-Services installed'

    try {
        Import-LabRequiredModule -Name ActiveDirectory -PrerequisiteMessage 'AD DS tools are missing.'
        $adDomain = Get-ADDomain -ErrorAction Stop
        $forest = Get-ADForest -ErrorAction Stop
        $domainOk = ($adDomain.DNSRoot -eq $domain.DnsName -and $adDomain.NetBIOSName -eq $domain.NetbiosName -and $forest.RootDomain -eq $domain.DnsName)
        $domainDetail = 'Domain={0}, NetBIOS={1}, Forest={2}' -f $adDomain.DNSRoot, $adDomain.NetBIOSName, $forest.RootDomain
    }
    catch {
        $domainOk = $false
        $domainDetail = $_.Exception.Message
    }
    Add-LabCheck -Name 'Forest/Domain' -Status ($(if ($domainOk) { 'PASS' } else { 'FAIL' })) -Detail $domainDetail

    try {
        Import-LabRequiredModule -Name DnsServer -PrerequisiteMessage 'DNS server tools are missing.'
        $dnsService = Get-Service -Name DNS -ErrorAction Stop
        $zone = Get-DnsServerZone -Name $domain.DnsName -ErrorAction Stop
        $hostRecord = @(Resolve-DnsName -Name $serverFqdn -Server $server.IPAddress -DnsOnly -ErrorAction Stop)
        $hostOk = @($hostRecord | Where-Object { $_.IPAddress -eq $server.IPAddress }).Count -gt 0
        $srvAnswers = @(Resolve-DnsName -Name ('_ldap._tcp.dc._msdcs.{0}' -f $domain.DnsName) -Type SRV -Server $server.IPAddress -DnsOnly -ErrorAction Stop)
        $srvTargets = @($srvAnswers | Where-Object { $_.NameTarget } | ForEach-Object { $_.NameTarget.TrimEnd('.').ToLowerInvariant() })
        $srvOk = @($srvTargets | Where-Object { $_ -eq $serverFqdn.ToLowerInvariant() }).Count -gt 0
        $dnsOk = ($dnsService.Status -eq 'Running' -and $zone.ZoneType -eq 'Primary' -and $zone.IsDsIntegrated -eq $true -and $hostOk -and $srvOk)
        $dnsDetail = 'Service={0}, ZoneType={1}, DsIntegrated={2}, A={3}, SRV={4}' -f $dnsService.Status, $zone.ZoneType, $zone.IsDsIntegrated, $hostOk, $srvOk
    }
    catch {
        $dnsOk = $false
        $dnsDetail = $_.Exception.Message
    }
    Add-LabCheck -Name 'DNS Server' -Status ($(if ($dnsOk) { 'PASS' } else { 'FAIL' })) -Detail $dnsDetail

    try {
        $dc = @(Get-ADDomainController -Filter * -ErrorAction Stop | Where-Object { $_.Name -eq $server.Name }) | Select-Object -First 1
        if ($dc) {
            $dcOk = ((@($dc.IPv4Address) -contains $server.IPAddress) -and [bool]$dc.IsGlobalCatalog -and [bool]$dc.Enabled -and @($dc.OperationMasterRoles).Count -eq 5)
            $dcDetail = 'IPv4={0}, GC={1}, Enabled={2}, FSMO={3}' -f (@($dc.IPv4Address) -join ','), $dc.IsGlobalCatalog, $dc.Enabled, @($dc.OperationMasterRoles).Count
        }
        else {
            $dcOk = $false
            $dcDetail = 'DC object not found'
        }
    }
    catch {
        $dcOk = $false
        $dcDetail = $_.Exception.Message
    }
    Add-LabCheck -Name 'Domain Controller' -Status ($(if ($dcOk) { 'PASS' } else { 'FAIL' })) -Detail $dcDetail

    $sysvolOk = Test-Path -LiteralPath ('\\{0}\SYSVOL' -f $server.Name)
    Add-LabCheck -Name 'SYSVOL' -Status ($(if ($sysvolOk) { 'PASS' } else { 'FAIL' })) -Detail ('\\{0}\SYSVOL' -f $server.Name)
    $netlogonOk = Test-Path -LiteralPath ('\\{0}\NETLOGON' -f $server.Name)
    Add-LabCheck -Name 'NETLOGON' -Status ($(if ($netlogonOk) { 'PASS' } else { 'FAIL' })) -Detail ('\\{0}\NETLOGON' -f $server.Name)

    try {
        $dhcpFeature = Get-WindowsFeature -Name DHCP -ErrorAction Stop
        $dhcpInstalled = ($dhcpFeature.InstallState.ToString() -eq 'Installed')
    }
    catch {
        $dhcpInstalled = $false
    }
    Add-LabCheck -Name 'DHCP Role' -Status ($(if ($dhcpInstalled) { 'PASS' } else { 'FAIL' })) -Detail 'DHCP installed'

    try {
        Import-LabRequiredModule -Name DhcpServer -PrerequisiteMessage 'DHCP tools are missing.'
        $entries = @(Get-DhcpServerInDC -ErrorAction Stop)
        $entry = @($entries | Where-Object { ([string]$_.IPAddress) -eq $server.IPAddress }) | Select-Object -First 1
        $authorizationOk = ($entry -and (([string]$entry.DnsName).TrimEnd('.') -eq $serverFqdn.TrimEnd('.')))
        $authorizationDetail = if ($entry) { '{0} / {1}' -f $entry.DnsName, $entry.IPAddress } else { 'No authorization entry for 192.168.63.2' }
    }
    catch {
        $authorizationOk = $false
        $authorizationDetail = $_.Exception.Message
    }
    Add-LabCheck -Name 'DHCP Authorization' -Status ($(if ($authorizationOk) { 'PASS' } else { 'FAIL' })) -Detail $authorizationDetail

    try {
        $scope = Get-DhcpServerv4Scope -ScopeId $scopeId -ErrorAction Stop
        $scopeOk = (
            ([string]$scope.Name -eq $dhcp.ScopeName) -and
            ([string]$scope.StartRange -eq $dhcp.StartRange) -and
            ([string]$scope.EndRange -eq $dhcp.EndRange) -and
            ([string]$scope.SubnetMask -eq $server.SubnetMask) -and
            ($scope.State -eq 'Active') -and
            ([math]::Abs($scope.LeaseDuration.TotalDays - $dhcp.LeaseDays) -lt 0.01)
        )
        $scopeDetail = 'Name={0}, Range={1}-{2}, State={3}, LeaseDays={4}' -f $scope.Name, $scope.StartRange, $scope.EndRange, $scope.State, $scope.LeaseDuration.TotalDays
    }
    catch {
        $scopeOk = $false
        $scopeDetail = $_.Exception.Message
    }
    Add-LabCheck -Name 'DHCP Scope' -Status ($(if ($scopeOk) { 'PASS' } else { 'FAIL' })) -Detail $scopeDetail

    try {
        $options = @(Get-DhcpServerv4OptionValue -ScopeId $scopeId -ErrorAction Stop)
        $dnsOption = @($options | Where-Object { $_.OptionId -eq 6 }) | Select-Object -First 1
        $domainOption = @($options | Where-Object { $_.OptionId -eq 15 }) | Select-Object -First 1
        $routerOption = @($options | Where-Object { $_.OptionId -eq 3 })
        $actualDns = @()
        if ($dnsOption) { $actualDns = @($dnsOption.Value | ForEach-Object { [string]$_ }) }
        $actualDomain = ''
        if ($domainOption) { $actualDomain = [string]$domainOption.Value }
        $binding = @(Get-DhcpServerv4Binding -ErrorAction Stop | Where-Object { ([string]$_.IPAddress) -eq $server.IPAddress -and $_.BindingState -eq $true })
        $serverRouterOption = @(Get-DhcpServerv4OptionValue -OptionId 3 -ErrorAction SilentlyContinue | Where-Object { $_.OptionId -eq 3 })
        $optionsOk = (
            ((($actualDns | Sort-Object) -join ',') -eq ((@($dhcp.DnsServers) | Sort-Object) -join ',')) -and
            ($actualDomain -eq $dhcp.DnsDomain) -and
            ($routerOption.Count -eq 0) -and
            ($serverRouterOption.Count -eq 0) -and
            ($binding.Count -gt 0)
        )
        $optionsDetail = '006={0}, 015={1}, scope003Count={2}, server003Count={3}, Binding={4}' -f ($actualDns -join ', '), $actualDomain, $routerOption.Count, $serverRouterOption.Count, ($binding.Count -gt 0)
    }
    catch {
        $optionsOk = $false
        $optionsDetail = $_.Exception.Message
    }
    Add-LabCheck -Name 'DHCP Options' -Status ($(if ($optionsOk) { 'PASS' } else { 'FAIL' })) -Detail $optionsDetail

    $dhcpService = Get-Service -Name DHCPServer -ErrorAction SilentlyContinue
    Add-LabCheck -Name 'DHCP Service' -Status ($(if ($dhcpService -and $dhcpService.Status -eq 'Running') { 'PASS' } else { 'FAIL' })) -Detail ($(if ($dhcpService) { $dhcpService.Status.ToString() } else { 'service not found' }))

    return (Write-LabCheckSummary)
}

function Show-LabServerStatus {
    param(
        [Parameter(Mandatory = $true)]
        $Config,
        [Parameter(Mandatory = $true)]
        $Context,
        $State
    )

    Write-LabLog -Level STEP -Message '=== SERVER STATUS (read-only) ==='
    if ($State) {
        Write-LabLog -Level INFO -Message ('State file : {0}' -f $Context.StateFile)
        Write-LabLog -Level INFO -Message ('Checkpoint : {0}' -f $State.Checkpoint)
        Write-LabLog -Level INFO -Message ('RebootCount: {0}' -f $State.RebootCount)
        Write-LabLog -Level INFO -Message ('LastScript : {0} (exit {1})' -f $State.LastScript, $State.LastExitCode)
    }
    else {
        Write-LabLog -Level INFO -Message ('State file : not found ({0})' -f $Context.StateFile)
    }

    $actual = Get-LabServerActualState -Config $Config
    Write-LabLog -Level INFO -Message ('Computer   : {0} | role {1} | domain {2}' -f $actual.ComputerState.Name, (Get-LabDomainRoleName -DomainRole $actual.DomainRole), $actual.ComputerState.Domain)
    Write-LabLog -Level INFO -Message ('Network    : IPv4={0} | DNS={1} | defaultRoutes={2}' -f (($actual.Addresses | ForEach-Object { '{0}/{1}' -f $_.IPAddress, $_.PrefixLength }) -join ', '), (@($actual.DnsServers) -join ', '), (-not $actual.NoDefaultRoute))
    Write-LabLog -Level INFO -Message ('AD DS      : roleInstalled={0} | DC={1} | operational={2} | promotionEvidence={3}' -f $actual.AdDsRoleInstalled, $actual.IsDcRole, $actual.DcOperational, $actual.PromotionEvidence)

    $dhcpStatus = Get-LabServerDhcpStatus -Config $Config
    Write-LabLog -Level INFO -Message ('DHCP       : installed={0} | service={1} | authorized={2} | scope={3} | options={4} | server003={5} | binding={6}' -f $dhcpStatus.Installed, $dhcpStatus.ServiceRunning, $dhcpStatus.Authorized, $dhcpStatus.ScopeOk, $dhcpStatus.OptionsOk, $dhcpStatus.ServerRouterOptions, $dhcpStatus.BindingOk)

    $task = Get-LabResumeTask -Context $Context
    if ($task) {
        Write-LabLog -Level INFO -Message ('Resume task: {0} | state {1}' -f $task.TaskName, $task.State)
    }
    else {
        Write-LabLog -Level INFO -Message 'Resume task: not registered'
    }

    if ($actual.DcOperational -and $dhcpStatus.Ready) {
        Write-LabResultBanner -Message 'SERVER STATUS: READY' -Success $true
    }
    else {
        Write-LabResultBanner -Message 'SERVER STATUS: INCOMPLETE' -Success $false
    }
}

function Invoke-LabServerDcPhase {
    param(
        [Parameter(Mandatory = $true)]
        $Config,
        [Parameter(Mandatory = $true)]
        $Context,
        [Parameter(Mandatory = $true)]
        $State
    )

    $server = $Config.Server
    $domain = $Config.Domain
    $adapter = Get-LabNetworkAdapter -MacAddress $server.MacAddress -KnownIPs @($server.IPAddress, $server.BaselineIPAddress)

    Write-LabLog -Level STEP -Message 'Ensuring DNS client points to the configured domain controller address.'
    Set-LabDnsClientServers -InterfaceIndex $adapter.ifIndex -DnsServers $server.DnsServers | Out-Null
    [void](Set-LabOrchestratorCheckpoint -Context $Context -State $State -Checkpoint 'dns-configured')
    [void](Add-LabCompletedStep -Context $Context -State $State -Step 'dns-configured')

    $adReady = Wait-LabCondition -Condition {
        try {
            Import-LabRequiredModule -Name ActiveDirectory -PrerequisiteMessage 'AD DS tools are missing.'
            $adDomain = Get-ADDomain -ErrorAction Stop
            return ($adDomain.DNSRoot -eq $domain.DnsName)
        }
        catch {
            return $false
        }
    } -TimeoutSeconds 180 -IntervalSeconds 5 -Description 'AD DS domain controller availability'
    if (-not $adReady) {
        throw ('This server reports a domain controller role, but AD DS for {0} is not reachable. The DNS client was reset to {1}. Do not recreate the forest; review the AD DS/DNS services and logs.' -f $domain.DnsName, ($server.DnsServers -join ', '))
    }

    $completed = @($State.CompletedSteps)
    if ($completed -notcontains 'ad-verified') {
        Write-LabLog -Level STEP -Message 'Running AD DS/DNS verification.'
        $exitCode = Invoke-LabChildScript -ScriptPath (Join-Path $Context.Root 'SERVER\03-Verify-AD.ps1') -WorkingDirectory $Context.Root -LogDirectory $Context.LogDirectory
        if ($exitCode -eq 3) {
            Invoke-LabServerReboot -Context $Context -State $State -Checkpoint 'ad-verify-reboot' -LastScript '03-Verify-AD' -LastExitCode $exitCode
        }
        if ($exitCode -ne 0) {
            throw ('03-Verify-AD.ps1 failed with exit code {0}.' -f $exitCode)
        }
        [void](Add-LabCompletedStep -Context $Context -State $State -Step 'ad-verified')
    }
    else {
        Write-LabLog -Level INFO -Message 'AD DS verification is already recorded in the state file; running final checks after DHCP.'
    }

    $dhcpStatus = Get-LabServerDhcpStatus -Config $Config
    if (-not $dhcpStatus.Installed -or -not $dhcpStatus.ServiceRunning -or -not $dhcpStatus.Authorized -or (([string]$dhcpStatus.AuthorizedName).TrimEnd('.') -ne ([string]$dhcpStatus.ExpectedName).TrimEnd('.'))) {
        Write-LabLog -Level STEP -Message 'Installing/authorizing the DHCP Server role.'
        $exitCode = Invoke-LabChildScript -ScriptPath (Join-Path $Context.Root 'SERVER\04-Install-DHCP.ps1') -WorkingDirectory $Context.Root -LogDirectory $Context.LogDirectory
        if ($exitCode -eq 3) {
            Invoke-LabServerReboot -Context $Context -State $State -Checkpoint 'dhcp-install-reboot' -LastScript '04-Install-DHCP' -LastExitCode $exitCode
        }
        if ($exitCode -ne 0) {
            throw ('04-Install-DHCP.ps1 failed with exit code {0}.' -f $exitCode)
        }
        [void](Add-LabCompletedStep -Context $Context -State $State -Step 'dhcp-installed')
    }
    else {
        Write-LabLog -Level INFO -Message 'DHCP role, service, and AD authorization are already correct; 04 is skipped.'
    }

    $dhcpStatus = Get-LabServerDhcpStatus -Config $Config
    if (-not $dhcpStatus.ScopeOk -or -not $dhcpStatus.OptionsOk -or -not $dhcpStatus.BindingOk) {
        Write-LabLog -Level STEP -Message 'Configuring/validating the DHCP scope and options.'
        $exitCode = Invoke-LabChildScript -ScriptPath (Join-Path $Context.Root 'SERVER\05-Configure-DHCP.ps1') -WorkingDirectory $Context.Root -LogDirectory $Context.LogDirectory
        if ($exitCode -eq 3) {
            Invoke-LabServerReboot -Context $Context -State $State -Checkpoint 'dhcp-configure-reboot' -LastScript '05-Configure-DHCP' -LastExitCode $exitCode
        }
        if ($exitCode -ne 0) {
            throw ('05-Configure-DHCP.ps1 failed with exit code {0}.' -f $exitCode)
        }
        [void](Add-LabCompletedStep -Context $Context -State $State -Step 'dhcp-configured')
    }
    else {
        Write-LabLog -Level INFO -Message 'DHCP scope, options, and binding are already correct; 05 is skipped.'
    }

    [void](Set-LabOrchestratorCheckpoint -Context $Context -State $State -Checkpoint 'verifying')
    $result = Invoke-LabServerFinalChecks -Config $Config
    $statistics = Get-LabCheckStatistics
    Write-LabLog -Level INFO -Message ('Final counts: PASS={0} WARN={1} FAIL={2}' -f $statistics.Pass, $statistics.Warn, $statistics.Fail)

    if ($result -ne 'PASS' -or $statistics.Warn -gt 0 -or $statistics.Fail -gt 0) {
        throw 'Server final verification did not pass cleanly. Review the failed/warning checks and logs.'
    }

    $State.Checkpoint = 'complete'
    $State.PendingReboot = $false
    $State.LastError = ''
    $State.LastExitCode = 0
    $State.LastScript = 'START-SERVER'
    Save-LabOrchestratorState -Context $Context -State $State
    try { Unregister-LabResumeTask -Context $Context | Out-Null } catch { }

    Write-LabResultBanner -Message 'SERVER IS READY FOR CLIENT DEPLOYMENT' -Success $true
    return $true
}

$readOnlyMode = $false

try {
    Assert-LabAdministrator
    Assert-LabPowerShell51
    $config = Import-LabConfig -ScriptRoot $scriptRoot
    Start-LabSession -ScriptName 'START-SERVER' -LogDirectory $config.Paths.LogDirectory

    $server = $config.Server
    $domain = $config.Domain
    $mode = $PSCmdlet.ParameterSetName

    Write-LabLog -Level STEP -Message ('=== START-SERVER - mode {0} ===' -f $mode)
    if ($FromResumeTask) {
        Write-LabLog -Level INFO -Message 'Running from the automatic logon resume task.'
    }

    $readOnlyMode = ($mode -in @('Status', 'Verify'))
    $stateRead = Read-LabOrchestratorState -Context $context
    $state = $stateRead.State

    if ($stateRead.Corrupt) {
        Write-LabLog -Level WARN -Message ('State file is unreadable: {0}. Actual machine state will drive deployment/resume.' -f $context.StateFile)
    }
    if ($stateRead.Exists -and $state -and [string]$state.Role -ne 'SERVER') {
        Write-LabLog -Level WARN -Message ('State file belongs to role {0}, not SERVER.' -f $state.Role)
        $state = $null
    }

    if ($mode -eq 'Status') {
        Show-LabServerStatus -Config $config -Context $context -State $state
        exit 0
    }

    if (-not $readOnlyMode) {
        if ($stateRead.Corrupt) {
            $corruptBackup = '{0}.corrupt_{1}.json' -f $context.StateFile, (Get-Date -Format 'yyyyMMdd_HHmmss')
            try { Copy-Item -LiteralPath $context.StateFile -Destination $corruptBackup -Force } catch { }
            Write-LabLog -Level WARN -Message ('Corrupt state backup: {0}' -f $corruptBackup)
        }
        if (-not $state) {
            $state = New-LabOrchestratorState -Role 'SERVER'
            Save-LabOrchestratorState -Context $context -State $state
        }
    }

    $computerStateBefore = Get-LabComputerState
    if ($computerStateBefore.PartOfDomain -and $computerStateBefore.DomainRole -ge 4) {
        try {
            $adapterBefore = Get-LabNetworkAdapter -MacAddress $server.MacAddress -KnownIPs @($server.IPAddress, $server.BaselineIPAddress)
            $dnsBefore = @(Get-LabDnsClientServers -InterfaceIndex $adapterBefore.ifIndex)
            if ((($dnsBefore | Sort-Object) -join ',') -ne ((@($server.DnsServers) | Sort-Object) -join ',')) {
                if ($mode -eq 'Verify') {
                    Write-LabLog -Level WARN -Message ('DNS client points to {0}; expected {1}. -Verify is read-only and will report this as a failure.' -f ($dnsBefore -join ', '), ($server.DnsServers -join ', '))
                }
                else {
                    Write-LabLog -Level WARN -Message ('DNS client points to {0}; expected {1}. Resetting it before AD DS verification.' -f ($dnsBefore -join ', '), ($server.DnsServers -join ', '))
                    Set-LabDnsClientServers -InterfaceIndex $adapterBefore.ifIndex -DnsServers $server.DnsServers | Out-Null
                }
            }
        }
        catch {
            Write-LabLog -Level WARN -Message ('Early DNS client enforcement could not be completed: {0}' -f $_.Exception.Message)
        }
    }

    $actual = Get-LabServerActualState -Config $config

    if ($mode -eq 'Verify') {
        if (-not $actual.IsDcRole -or -not $actual.DcOperational) {
            Add-LabCheck -Name 'Domain Controller' -Status 'FAIL' -Detail 'The server is not an operational domain controller.'
            [void](Write-LabCheckSummary)
            Write-LabResultBanner -Message 'SERVER VERIFICATION FAILED' -Success $false
            exit 2
        }
        $result = Invoke-LabServerFinalChecks -Config $config
        if ($result -eq 'PASS') {
            Write-LabResultBanner -Message 'SERVER IS READY FOR CLIENT DEPLOYMENT' -Success $true
            exit 0
        }
        Write-LabResultBanner -Message 'SERVER VERIFICATION FAILED' -Success $false
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
        Invoke-LabServerReboot -Context $context -State $state -Checkpoint 'pending-reboot' -LastScript 'pending-reboot' -LastExitCode 3
    }

    if ($actual.IsDcRole) {
        if (-not $actual.DcOperational) {
            throw ('The server has a domain controller role but AD DS is not reachable. DNS was reset to {0}; do not create a new forest. Review AD DS/DNS.' -f ($server.DnsServers -join ', '))
        }
        [void](Invoke-LabServerDcPhase -Config $config -Context $context -State $state)
        exit 0
    }

    if ($actual.PartOfDomain) {
        throw ('The server is a member of domain {0}, but this lab expects a standalone server before forest creation. No changes were made.' -f $actual.ComputerState.Domain)
    }

    if ($actual.PromotionEvidence) {
        Write-LabLog -Level ERROR -Message 'AD DS promotion evidence exists, but this server is not an operational domain controller.'
        Write-LabLog -Level ERROR -Message 'Do not run promotion again. Reboot and inspect AD DS/DNS, then use -Resume or restore Snapshot Lab 1 if the promotion is incomplete.'
        throw 'Unsafe AD DS promotion state detected. No promotion was attempted.'
    }

    if (-not $actual.NameOk -or -not $actual.IpOk -or -not $actual.DnsOk -or -not $actual.NoDefaultRoute) {
        Write-LabLog -Level STEP -Message 'Preparing server name, static IPv4, DNS, and default route.'
        [void](Set-LabOrchestratorCheckpoint -Context $context -State $state -Checkpoint 'network-preparing')
        $exitCode = Invoke-LabChildScript -ScriptPath (Join-Path $context.Root 'SERVER\01-Server-Prepare.ps1') -WorkingDirectory $context.Root -LogDirectory $context.LogDirectory
        if ($exitCode -eq 3) {
            [void](Add-LabCompletedStep -Context $context -State $state -Step 'network-prepared')
            Invoke-LabServerReboot -Context $context -State $state -Checkpoint 'network-reboot' -LastScript '01-Server-Prepare' -LastExitCode $exitCode
        }
        if ($exitCode -ne 0) {
            throw ('01-Server-Prepare.ps1 failed with exit code {0}.' -f $exitCode)
        }
        [void](Add-LabCompletedStep -Context $context -State $state -Step 'network-prepared')
    }
    else {
        Write-LabLog -Level INFO -Message 'Server name, static IPv4, DNS, and default route are already correct; 01 is skipped.'
    }

    $actual = Get-LabServerActualState -Config $config
    $pending = Get-LabPendingReboot
    if ($pending.Pending) {
        Invoke-LabServerReboot -Context $context -State $state -Checkpoint 'network-reboot' -LastScript 'pending-reboot' -LastExitCode 3
    }
    if (-not $actual.NameOk -or -not $actual.IpOk -or -not $actual.DnsOk -or -not $actual.NoDefaultRoute) {
        throw 'Server network preparation did not reach the configured target state.'
    }
    if ($actual.PromotionEvidence) {
        throw 'AD DS promotion evidence appeared during preparation. No promotion was attempted; inspect the server.'
    }

    Write-LabLog -Level STEP -Message 'Installing/validating AD DS and creating the forest.'
    [void](Set-LabOrchestratorCheckpoint -Context $context -State $state -Checkpoint 'promoting')
    $exitCode = Invoke-LabChildScript -ScriptPath (Join-Path $context.Root 'SERVER\02-Install-ADDS.ps1') -WorkingDirectory $context.Root -LogDirectory $context.LogDirectory
    if ($exitCode -eq 3) {
        $afterPromotion = Get-LabServerActualState -Config $config
        if ($afterPromotion.DcOperational -or $afterPromotion.PromotionEvidence) {
            [void](Add-LabCompletedStep -Context $context -State $state -Step 'ad-promotion-staged')
            Invoke-LabServerReboot -Context $context -State $state -Checkpoint 'ad-promotion-reboot' -LastScript '02-Install-ADDS' -LastExitCode $exitCode
        }
        Invoke-LabServerReboot -Context $context -State $state -Checkpoint 'ad-role-reboot' -LastScript '02-Install-ADDS' -LastExitCode $exitCode
    }
    if ($exitCode -ne 0) {
        throw ('02-Install-ADDS.ps1 failed with exit code {0}. Do not rerun promotion blindly.' -f $exitCode)
    }

    $actual = Get-LabServerActualState -Config $config
    if (-not $actual.IsDcRole -or -not $actual.DcOperational) {
        throw '02-Install-ADDS.ps1 returned success, but the server is not an operational domain controller.'
    }

    [void](Invoke-LabServerDcPhase -Config $config -Context $context -State $state)
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
    Write-LabResultBanner -Message 'SERVER DEPLOYMENT FAILED' -Success $false
    exit 2
}

