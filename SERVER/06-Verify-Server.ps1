<#
.SYNOPSIS
    SERVER 06 - Verify AD DS, DNS, DHCP and the WRK01 lease on EAUT-SRV12 (read-only).

.DESCRIPTION
    Target machine : EAUT-SRV12, after 01-05.
    Changes made   : NONE. This script only inspects and reports.
    Checks         : AD DS/DNS quick health, DHCP role/service/authorization/scope/options/
                     binding, DHCP leases (WRK01), AD computer object WRK01, firewall state.

.PARAMETER RequireClientLease
    Makes the final WRK01 DHCP lease check mandatory. Use this for the last evidence run
    after CLIENT 03/04. Without this switch, a missing lease is reported as WARN.

.NOTES
    Reboot required : NO.
    Expected output : RESULT: PASS (or PASS WITH WARNINGS before the client is configured).
                     Warnings are expected if WRK01 has not joined/renewed yet.
    Exit codes      : 0 no critical failure, 2 one or more checks failed.
    Safe to rerun   : YES. Run again after CLIENT 04 to capture lease evidence.
#>
[CmdletBinding()]
param(
    [switch]$RequireClientLease
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$modulePath = Join-Path -Path (Split-Path -Parent $scriptRoot) -ChildPath 'LIB\LabCommon.psm1'

if (-not (Test-Path -LiteralPath $modulePath)) {
    Write-Host ('ERROR: LabCommon.psm1 not found at {0}. Copy the entire EAUT-AD-DHCP-LAB folder.' -f $modulePath) -ForegroundColor Red
    exit 2
}

Import-Module -Name $modulePath -Force

try {
    Assert-LabAdministrator
    Assert-LabPowerShell51
    $config = Import-LabConfig -ScriptRoot $scriptRoot
    Start-LabSession -ScriptName '06-Verify-Server' -LogDirectory $config.Paths.LogDirectory

    $server = $config.Server
    $client = $config.Client
    $domain = $config.Domain
    $dhcp = $config.Dhcp
    $serverFqdn = '{0}.{1}' -f $server.Name, $domain.DnsName
    $scopeId = Get-LabScopeId -IPAddress $dhcp.StartRange -PrefixLength $server.PrefixLength

    Write-LabLog -Level STEP -Message '=== SERVER 06 - Verify server health (read-only) ==='

    $state = Get-LabComputerState
    Write-LabComputerState -State $state

    $pending = Get-LabPendingReboot
    Add-LabCheck -Name 'No pending reboot' -Status ($(if ($pending.Pending) { 'WARN' } else { 'PASS' })) -Detail ($(if ($pending.Pending) { $pending.Reasons -join '; ' } else { 'none' }))

    if (-not $state.PartOfDomain -or $state.DomainRole -lt 4) {
        Add-LabCheck -Name 'Domain controller role' -Status 'FAIL' -Detail ('PartOfDomain={0}, Role={1}' -f $state.PartOfDomain, (Get-LabDomainRoleName -DomainRole $state.DomainRole))
        [void](Write-LabCheckSummary)
        exit 2
    }

    Import-LabRequiredModule -Name ActiveDirectory -PrerequisiteMessage 'AD DS tools are missing.'
    Import-LabRequiredModule -Name DnsServer -PrerequisiteMessage 'DNS server tools are missing.'

    try {
        $adDomain = Get-ADDomain -ErrorAction Stop
        $domainOk = ($adDomain.DNSRoot -eq $domain.DnsName) -and ($adDomain.NetBIOSName -eq $domain.NetbiosName)
        Add-LabCheck -Name 'AD domain identity' -Status ($(if ($domainOk) { 'PASS' } else { 'FAIL' })) -Detail ('DNSRoot={0}, NetBIOS={1}' -f $adDomain.DNSRoot, $adDomain.NetBIOSName)
    }
    catch {
        Add-LabCheck -Name 'AD domain identity' -Status 'FAIL' -Detail $_.Exception.Message
    }

    $serviceNames = @('NTDS', 'DNS', 'Netlogon', 'KDC', 'DFSR')
    $serviceObjects = @(Get-Service -Name $serviceNames -ErrorAction SilentlyContinue)
    $notRunning = @($serviceObjects | Where-Object { $_.Status -ne 'Running' })
    Add-LabCheck -Name 'AD DS core services' -Status ($(if ($serviceObjects.Count -eq $serviceNames.Count -and $notRunning.Count -eq 0) { 'PASS' } else { 'FAIL' })) -Detail (($serviceObjects | ForEach-Object { '{0}={1}' -f $_.Name, $_.Status }) -join ', ')

    $sysvolOk = (Test-Path -LiteralPath ('\\{0}\SYSVOL' -f $server.Name)) -and (Test-Path -LiteralPath ('\\{0}\NETLOGON' -f $server.Name))
    Add-LabCheck -Name 'SYSVOL/NETLOGON shares' -Status ($(if ($sysvolOk) { 'PASS' } else { 'FAIL' })) -Detail ('\\{0}\SYSVOL, \\{0}\NETLOGON' -f $server.Name)

    $adapter = Get-LabNetworkAdapter -MacAddress $server.MacAddress -KnownIPs @($server.IPAddress, $server.BaselineIPAddress)
    $serverAddresses = @(Get-LabInterfaceAddresses -InterfaceIndex $adapter.ifIndex)
    $serverTarget = @($serverAddresses | Where-Object { $_.IPAddress -eq $server.IPAddress -and $_.PrefixLength -eq $server.PrefixLength })
    $serverUnexpected = @($serverAddresses | Where-Object {
            $_.IPAddress -ne $server.IPAddress -and
            $_.PrefixOrigin -ne 'WellKnown' -and
            -not $_.IPAddress.StartsWith('169.254.')
        })
    Add-LabCheck -Name ('Static IPv4 {0}/{1}' -f $server.IPAddress, $server.PrefixLength) -Status ($(if ($serverTarget.Count -eq 1 -and $serverUnexpected.Count -eq 0) { 'PASS' } else { 'FAIL' })) -Detail (($serverAddresses | ForEach-Object { '{0}/{1}' -f $_.IPAddress, $_.PrefixLength }) -join ', ')
    $dnsObject = Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    $dnsNow = @()
    if ($dnsObject) { $dnsNow = @($dnsObject.ServerAddresses) }
    Add-LabCheck -Name 'DNS client points to DC' -Status ($(if (((($dnsNow | Sort-Object) -join ',') -eq $server.IPAddress)) { 'PASS' } else { 'FAIL' })) -Detail ($dnsNow -join ', ')

    try {
        $srvAnswer = @(Resolve-DnsName -Name ('_ldap._tcp.dc._msdcs.{0}' -f $domain.DnsName) -Type SRV -Server $server.IPAddress -DnsOnly -ErrorAction Stop)
        $srvTargets = @($srvAnswer | Where-Object { $_.NameTarget } | ForEach-Object { $_.NameTarget.TrimEnd('.').ToLowerInvariant() })
        $srvOk = @($srvTargets | Where-Object { $_ -eq $serverFqdn.ToLowerInvariant() }).Count -gt 0
        Add-LabCheck -Name 'AD LDAP SRV record' -Status ($(if ($srvOk) { 'PASS' } else { 'FAIL' })) -Detail ($srvTargets -join ', ')
    }
    catch {
        Add-LabCheck -Name 'AD LDAP SRV record' -Status 'FAIL' -Detail $_.Exception.Message
    }

    $defaultRoutes = @(Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
    Add-LabCheck -Name 'No default gateway (by design)' -Status ($(if ($defaultRoutes.Count -eq 0) { 'PASS' } else { 'FAIL' })) -Detail ('Default routes: {0}' -f $defaultRoutes.Count)

    $dhcpFeature = Get-WindowsFeature -Name DHCP
    $dhcpInstalled = ($dhcpFeature.InstallState.ToString() -eq 'Installed')
    Add-LabCheck -Name 'DHCP Server role installed' -Status ($(if ($dhcpInstalled) { 'PASS' } else { 'FAIL' })) -Detail $dhcpFeature.InstallState.ToString()

    if ($dhcpInstalled) {
        Import-LabRequiredModule -Name DhcpServer -PrerequisiteMessage 'DHCP management tools are missing.'

        $service = Get-Service -Name DHCPServer -ErrorAction SilentlyContinue
        Add-LabCheck -Name 'DHCP service running' -Status ($(if ($service -and $service.Status -eq 'Running') { 'PASS' } else { 'FAIL' })) -Detail ($(if ($service) { $service.Status.ToString() } else { 'service not found' }))

        try {
            $entries = @(Get-DhcpServerInDC -ErrorAction Stop)
            $authorizedEntry = @($entries | Where-Object { ([string]$_.IPAddress) -eq $server.IPAddress }) | Select-Object -First 1
            $authorizationStatus = if (-not $authorizedEntry) { 'FAIL' } elseif (([string]$authorizedEntry.DnsName).TrimEnd('.') -ne $serverFqdn.TrimEnd('.')) { 'WARN' } else { 'PASS' }
            Add-LabCheck -Name 'DHCP authorized in AD' -Status $authorizationStatus -Detail ($(if ($authorizedEntry) { '{0} / {1}' -f $authorizedEntry.DnsName, $authorizedEntry.IPAddress } else { 'no entry for 192.168.63.2' }))
        }
        catch {
            Add-LabCheck -Name 'DHCP authorized in AD' -Status 'FAIL' -Detail $_.Exception.Message
        }

        $scope = $null
        try {
            $scope = Get-DhcpServerv4Scope -ScopeId $scopeId -ErrorAction Stop
        }
        catch {
            $scope = $null
        }

        if ($scope) {
            $scopeOk = (([string]$scope.Name -eq $dhcp.ScopeName) -and ([string]$scope.StartRange -eq $dhcp.StartRange) -and ([string]$scope.EndRange -eq $dhcp.EndRange) -and ([string]$scope.SubnetMask -eq $server.SubnetMask) -and ($scope.State -eq 'Active') -and ([math]::Abs($scope.LeaseDuration.TotalDays - $dhcp.LeaseDays) -lt 0.01))
            Add-LabCheck -Name 'DHCP scope configuration' -Status ($(if ($scopeOk) { 'PASS' } else { 'FAIL' })) -Detail ('Name={0}, Range={1}-{2}, State={3}, LeaseDays={4}' -f $scope.Name, $scope.StartRange, $scope.EndRange, $scope.State, $scope.LeaseDuration.TotalDays)

            $options = @(Get-DhcpServerv4OptionValue -ScopeId $scopeId -ErrorAction Stop)
            $dnsOption = @($options | Where-Object { $_.OptionId -eq 6 }) | Select-Object -First 1
            $domainOption = @($options | Where-Object { $_.OptionId -eq 15 }) | Select-Object -First 1
            $routerOption = @($options | Where-Object { $_.OptionId -eq 3 })

            $actualDns = @()
            if ($dnsOption) { $actualDns = @($dnsOption.Value | ForEach-Object { [string]$_ }) }
            Add-LabCheck -Name 'DHCP option 006 DNS' -Status ($(if ((($actualDns | Sort-Object) -join ',') -eq ((@($dhcp.DnsServers) | Sort-Object) -join ',')) { 'PASS' } else { 'FAIL' })) -Detail ($actualDns -join ', ')

            $actualDomain = ''
            if ($domainOption) { $actualDomain = [string]$domainOption.Value }
            Add-LabCheck -Name 'DHCP option 015 DNS domain' -Status ($(if ($actualDomain -eq $dhcp.DnsDomain) { 'PASS' } else { 'FAIL' })) -Detail $actualDomain

            if ($dhcp.Router) {
                $actualRouter = @()
                if ($routerOption.Count -gt 0) { $actualRouter = @($routerOption[0].Value | ForEach-Object { [string]$_ }) }
                Add-LabCheck -Name 'DHCP option 003 Router' -Status ($(if (@($actualRouter | Where-Object { $_ -eq $dhcp.Router }).Count -gt 0) { 'PASS' } else { 'FAIL' })) -Detail ($actualRouter -join ', ')
            }
            else {
                Add-LabCheck -Name 'DHCP option 003 absent (no gateway)' -Status ($(if ($routerOption.Count -eq 0) { 'PASS' } else { 'FAIL' })) -Detail ('Option 003 entries: {0}' -f $routerOption.Count)
            }

            $binding = @(Get-DhcpServerv4Binding -ErrorAction SilentlyContinue | Where-Object { ([string]$_.IPAddress) -eq $server.IPAddress -and $_.BindingState -eq $true })
            Add-LabCheck -Name 'DHCP bound to server IPv4' -Status ($(if ($binding.Count -gt 0) { 'PASS' } else { 'FAIL' })) -Detail $server.IPAddress

            try {
                $statistics = Get-DhcpServerv4ScopeStatistics -ScopeId $scopeId -ErrorAction Stop
                Add-LabCheck -Name 'DHCP scope statistics' -Status 'INFO' -Detail ('Free={0}, InUse={1}, Reserved={2}, Pending={3}' -f $statistics.Free, $statistics.InUse, $statistics.Reserved, $statistics.PendingOffer)
            }
            catch {
                Add-LabCheck -Name 'DHCP scope statistics' -Status 'WARN' -Detail $_.Exception.Message
            }

            $leases = @(Get-DhcpServerv4Lease -ScopeId $scopeId -ErrorAction SilentlyContinue)
            $clientMac = ($client.MacAddress -replace '[:-]', '').ToUpperInvariant()
            $clientLease = @($leases | Where-Object {
                    (((([string]$_.ClientId -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()) -replace '^.*([0-9A-F]{12})$', '$1') -eq $clientMac)
                }) | Select-Object -First 1
            if (-not $clientLease) {
                $clientLease = @($leases | Where-Object { [string]$_.HostName -like ($client.Name + '*') }) | Select-Object -First 1
            }

            if ($clientLease) {
                $leaseClientId = ([string]$clientLease.ClientId -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
                if ($leaseClientId.Length -gt 12) { $leaseClientId = $leaseClientId.Substring($leaseClientId.Length - 12) }
                $leaseMacOk = ($leaseClientId -eq $clientMac)
                $leaseActive = ([string]$clientLease.AddressState -eq 'Active')
                $leaseStatus = if ($leaseActive -and $leaseMacOk) { 'PASS' } elseif ($RequireClientLease) { 'FAIL' } else { 'WARN' }
                Add-LabCheck -Name 'WRK01 DHCP lease' -Status $leaseStatus -Detail ('IP={0}, Host={1}, ClientId={2}, State={3}, Expires={4}' -f $clientLease.IPAddress, $clientLease.HostName, $clientLease.ClientId, $clientLease.AddressState, $clientLease.LeaseExpiryTime)
            }
            else {
                $leaseStatus = if ($RequireClientLease) { 'FAIL' } else { 'WARN' }
                Add-LabCheck -Name 'WRK01 DHCP lease' -Status $leaseStatus -Detail 'No lease for WRK01 yet. Run the CLIENT scripts, then rerun 06.'
            }

            $reservations = @(Get-DhcpServerv4Reservation -ScopeId $scopeId -ErrorAction SilentlyContinue)
            Add-LabCheck -Name 'DHCP reservations' -Status 'INFO' -Detail ('Count={0} (none expected)' -f $reservations.Count)
        }
        else {
            Add-LabCheck -Name 'DHCP scope exists' -Status 'FAIL' -Detail ('Scope {0} not found. Run 05-Configure-DHCP.ps1.' -f $scopeId)
        }
    }

    try {
        $computerObject = Get-ADComputer -Identity $client.Name -ErrorAction Stop
        Add-LabCheck -Name 'WRK01 AD computer object' -Status 'PASS' -Detail ('DN={0}' -f $computerObject.DistinguishedName)
    }
    catch {
        Add-LabCheck -Name 'WRK01 AD computer object' -Status 'WARN' -Detail 'WRK01 is not in AD yet (expected before the client joins).'
    }

    $firewall = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue)
    $firewallEnabled = @($firewall | Where-Object { $_.Enabled -eq $true })
    Add-LabCheck -Name 'Firewall profile state' -Status 'INFO' -Detail ($(if ($firewallEnabled.Count -eq 0) { 'All profiles disabled; this script does not change firewall policy' } else { 'Enabled: ' + (($firewallEnabled | ForEach-Object { $_.Name }) -join ', ') }))

    $result = Write-LabCheckSummary
    if ($result -eq 'FAIL') {
        Write-LabLog -Level ERROR -Message 'Server verification FAILED. Review failed checks before configuring the client.'
        exit 2
    }

    Write-LabLog -Level SUCCESS -Message 'Server verification completed. If WARN only, proceed to the CLIENT scripts and rerun 06 afterwards for lease evidence.'
    exit 0
}
catch {
    $message = $_.Exception.Message
    try { Write-LabLog -Level ERROR -Message ('FATAL: {0}' -f $message) } catch { Write-Host ('FATAL: {0}' -f $message) -ForegroundColor Red }
    exit 2
}
