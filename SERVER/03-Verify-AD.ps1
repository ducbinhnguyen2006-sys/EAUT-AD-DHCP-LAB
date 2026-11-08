<#
.SYNOPSIS
    SERVER 03 - Verify AD DS and DNS health on EAUT-SRV12 (read-only).

.DESCRIPTION
    Target machine : EAUT-SRV12 (Windows Server 2019) after 02-Install-ADDS.ps1 and reboot.
    Changes made   : NONE. This script only inspects and reports.
    Checks         : domain role, AD services, SYSVOL/NETLOGON, domain/forest identity,
                     domain controller details, DNS zone, A/SRV records, DNS client,
                     dcdiag core tests, firewall state and time service.

.NOTES
    Reboot required : NO. Must be run AFTER the manual reboot that follows promotion.
    Expected output : RESULT: PASS and exit code 0 when all critical checks pass.
    Exit codes      : 0 all critical checks pass, 2 one or more checks failed,
                      3 reboot still required.
    Safe to rerun   : YES. Read-only script.
#>
[CmdletBinding()]
param()

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
    Start-LabSession -ScriptName '03-Verify-AD' -LogDirectory $config.Paths.LogDirectory

    $server = $config.Server
    $domain = $config.Domain
    $serverFqdn = '{0}.{1}' -f $server.Name, $domain.DnsName

    Write-LabLog -Level STEP -Message '=== SERVER 03 - Verify AD DS and DNS (read-only) ==='

    $state = Get-LabComputerState
    Write-LabComputerState -State $state

    $pending = Get-LabPendingReboot
    if ($pending.Pending) {
        foreach ($reason in $pending.Reasons) {
            Write-LabLog -Level ERROR -Message ('Pending reboot reason: {0}' -f $reason)
        }
        Add-LabCheck -Name 'No pending reboot' -Status 'FAIL' -Detail 'Reboot the VM manually before verification.'
        [void](Write-LabCheckSummary)
        exit 3
    }

    if (-not $state.PartOfDomain -or $state.DomainRole -lt 4) {
        $adDsState = Get-LabAdDsInstallState
        Add-LabCheck -Name 'Domain controller role' -Status 'FAIL' -Detail ('PartOfDomain={0}, Role={1}' -f $state.PartOfDomain, (Get-LabDomainRoleName -DomainRole $state.DomainRole))

        $promotionStaged = ($adDsState.NtdsDatabasePresent -or $adDsState.ProductType -eq 'LanmanNT' -or ($adDsState.NtdsServicePresent -and $adDsState.NtdsStartType -ne 'Disabled'))
        if ($promotionStaged) {
            Write-LabLog -Level WARN -Message 'AD DS promotion appears to be staged or partially applied. Reboot the VM manually from the console, then rerun 03. Do not rerun 02 blindly; if the server is still not a DC after reboot, restore Snapshot Lab 1.'
            [void](Write-LabCheckSummary)
            exit 3
        }

        Write-LabLog -Level ERROR -Message 'This computer is not a domain controller. Run 02-Install-ADDS.ps1 and reboot first. If the AD DS role is already installed with NTDS disabled, run 02 again to promote.'
        [void](Write-LabCheckSummary)
        exit 2
    }

    Import-LabRequiredModule -Name ActiveDirectory -PrerequisiteMessage 'AD DS role/promotion is missing.'
    Import-LabRequiredModule -Name DnsServer -PrerequisiteMessage 'DNS server role is missing.'

    $servicesReady = Wait-LabCondition -Condition {
        $expected = @('NTDS', 'DNS', 'Netlogon', 'KDC', 'DFSR')
        $services = @(Get-Service -Name $expected -ErrorAction SilentlyContinue)
        return ($services.Count -eq $expected.Count -and @($services | Where-Object { $_.Status -ne 'Running' }).Count -eq 0)
    } -TimeoutSeconds 180 -IntervalSeconds 5 -Description 'AD DS core services'

    if (-not $servicesReady) {
        Write-LabLog -Level WARN -Message 'Not all AD DS services reached Running state within 180 seconds; checks continue for diagnostics.'
    }

    try {
        $adDomain = Get-ADDomain -ErrorAction Stop
        $domainOk = ($adDomain.DNSRoot -eq $domain.DnsName) -and ($adDomain.NetBIOSName -eq $domain.NetbiosName)
        Add-LabCheck -Name 'AD domain identity' -Status ($(if ($domainOk) { 'PASS' } else { 'FAIL' })) -Detail ('DNSRoot={0}, NetBIOS={1}, DomainMode={2}' -f $adDomain.DNSRoot, $adDomain.NetBIOSName, $adDomain.DomainMode)

        if ($adDomain.DNSRoot -ne $domain.DnsName) {
            Write-LabLog -Level ERROR -Message ('Unexpected AD domain {0}. Expected {1}. Stopping verification.' -f $adDomain.DNSRoot, $domain.DnsName)
            [void](Write-LabCheckSummary)
            exit 2
        }
    }
    catch {
        Add-LabCheck -Name 'Get-ADDomain' -Status 'FAIL' -Detail $_.Exception.Message
        [void](Write-LabCheckSummary)
        exit 2
    }

    try {
        $forest = Get-ADForest -ErrorAction Stop
        $gcList = @($forest.GlobalCatalogs)
        $gcOk = @($gcList | Where-Object { $_ -eq $serverFqdn }).Count -gt 0
        Add-LabCheck -Name 'AD forest identity' -Status ($(if ($forest.RootDomain -eq $domain.DnsName -and $gcOk) { 'PASS' } else { 'FAIL' })) -Detail ('RootDomain={0}, ForestMode={1}, GlobalCatalogs={2}' -f $forest.RootDomain, $forest.ForestMode, ($gcList -join ', '))
    }
    catch {
        Add-LabCheck -Name 'Get-ADForest' -Status 'FAIL' -Detail $_.Exception.Message
    }

    try {
        $dc = @(Get-ADDomainController -Filter * -ErrorAction Stop | Where-Object { $_.Name -eq $server.Name }) | Select-Object -First 1
        if ($dc) {
            $dcIpOk = @($dc.IPv4Address) -contains $server.IPAddress
            $fsmoCount = @($dc.OperationMasterRoles).Count
            $dcOk = $dcIpOk -and [bool]$dc.IsGlobalCatalog -and [bool]$dc.Enabled -and $fsmoCount -eq 5
            Add-LabCheck -Name 'Domain controller details' -Status ($(if ($dcOk) { 'PASS' } else { 'FAIL' })) -Detail ('IPv4={0}, GC={1}, Enabled={2}, FSMO roles={3}' -f (@($dc.IPv4Address) -join ','), $dc.IsGlobalCatalog, $dc.Enabled, $fsmoCount)
        }
        else {
            Add-LabCheck -Name 'Domain controller details' -Status 'FAIL' -Detail ('No DC object named {0} returned by AD.' -f $server.Name)
        }
    }
    catch {
        Add-LabCheck -Name 'Get-ADDomainController' -Status 'FAIL' -Detail $_.Exception.Message
    }

    $serviceNames = @('NTDS', 'DNS', 'Netlogon', 'KDC', 'DFSR')
    $serviceObjects = @(Get-Service -Name $serviceNames -ErrorAction SilentlyContinue)
    $notRunning = @($serviceObjects | Where-Object { $_.Status -ne 'Running' })
    Add-LabCheck -Name 'AD DS core services' -Status ($(if ($serviceObjects.Count -eq $serviceNames.Count -and $notRunning.Count -eq 0) { 'PASS' } else { 'FAIL' })) -Detail (($serviceObjects | ForEach-Object { '{0}={1}' -f $_.Name, $_.Status }) -join ', ')

    $sysvolReady = $false
    for ($i = 0; $i -lt 24; $i++) {
        $sysvol = Test-Path -LiteralPath ('\\{0}\SYSVOL' -f $server.Name)
        $netlogon = Test-Path -LiteralPath ('\\{0}\NETLOGON' -f $server.Name)
        if ($sysvol -and $netlogon) {
            $sysvolReady = $true
            break
        }
        Start-Sleep -Seconds 5
    }
    Add-LabCheck -Name 'SYSVOL and NETLOGON shares' -Status ($(if ($sysvolReady) { 'PASS' } else { 'FAIL' })) -Detail ('\\{0}\SYSVOL, \\{0}\NETLOGON' -f $server.Name)

    $adapter = Get-LabNetworkAdapter -MacAddress $server.MacAddress -KnownIPs @($server.IPAddress, $server.BaselineIPAddress)
    $dnsObject = Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    $dnsNow = @()
    if ($dnsObject) { $dnsNow = @($dnsObject.ServerAddresses) }
    $dnsClientOk = ((($dnsNow | Sort-Object) -join ',') -eq $server.IPAddress)
    Add-LabCheck -Name 'DNS client points to DC' -Status ($(if ($dnsClientOk) { 'PASS' } else { 'FAIL' })) -Detail ($dnsNow -join ', ')

    try {
        $zone = Get-DnsServerZone -Name $domain.DnsName -ErrorAction Stop
        $zoneOk = ($zone.ZoneType -eq 'Primary') -and ($zone.IsDsIntegrated -eq $true)
        Add-LabCheck -Name 'DNS forward zone' -Status ($(if ($zoneOk) { 'PASS' } else { 'FAIL' })) -Detail ('ZoneType={0}, IsDsIntegrated={1}, DynamicUpdate={2}' -f $zone.ZoneType, $zone.IsDsIntegrated, $zone.DynamicUpdate)
    }
    catch {
        Add-LabCheck -Name 'DNS forward zone' -Status 'FAIL' -Detail $_.Exception.Message
    }

    try {
        $hostRecord = @(Resolve-DnsName -Name $serverFqdn -Server $server.IPAddress -DnsOnly -ErrorAction Stop)
        $hostOk = @($hostRecord | Where-Object { $_.IPAddress -eq $server.IPAddress }).Count -gt 0
        Add-LabCheck -Name 'DC host A record' -Status ($(if ($hostOk) { 'PASS' } else { 'FAIL' })) -Detail $serverFqdn
    }
    catch {
        Add-LabCheck -Name 'DC host A record' -Status 'FAIL' -Detail $_.Exception.Message
    }

    $srvNames = @(
        ('_ldap._tcp.dc._msdcs.{0}' -f $domain.DnsName),
        ('_kerberos._tcp.dc._msdcs.{0}' -f $domain.DnsName),
        ('_ldap._tcp.{0}' -f $domain.DnsName)
    )
    $srvOk = $true
    $srvDetails = New-Object System.Collections.Generic.List[string]
    foreach ($srvName in $srvNames) {
        try {
            $answers = @(Resolve-DnsName -Name $srvName -Type SRV -Server $server.IPAddress -DnsOnly -ErrorAction Stop)
            $targets = @($answers | Where-Object { $_.NameTarget } | ForEach-Object { $_.NameTarget.TrimEnd('.').ToLowerInvariant() })
            $match = @($targets | Where-Object { $_ -eq $serverFqdn.ToLowerInvariant() }).Count -gt 0
            if (-not $match) { $srvOk = $false }
            $srvDetails.Add(('{0} => {1}' -f $srvName, ($targets -join ', ')))
        }
        catch {
            $srvOk = $false
            $srvDetails.Add(('{0} => ERROR {1}' -f $srvName, $_.Exception.Message))
        }
    }
    Add-LabCheck -Name 'AD SRV records' -Status ($(if ($srvOk) { 'PASS' } else { 'FAIL' })) -Detail ($srvDetails -join ' | ')

    Write-LabLog -Level STEP -Message 'Running dcdiag core tests (connectivity, advertising, netlogons, services, frssysvol).'
    try {
        $dcdiagOutput = & dcdiag.exe /test:connectivity /test:advertising /test:netlogons /test:services /test:frssysvol /q 2>&1
        $dcdiagExit = $LASTEXITCODE
        foreach ($line in @($dcdiagOutput)) {
            if ($null -ne $line -and $line.ToString().Trim().Length -gt 0) {
                Write-LabLog -Level INFO -Message ('[DCDIAG] {0}' -f $line.ToString())
            }
        }
        Add-LabCheck -Name 'dcdiag core tests' -Status ($(if ($dcdiagExit -eq 0) { 'PASS' } else { 'FAIL' })) -Detail ('ExitCode={0}' -f $dcdiagExit)
    }
    catch {
        Add-LabCheck -Name 'dcdiag core tests' -Status 'FAIL' -Detail $_.Exception.Message
    }

    try {
        $timeOutput = & w32tm.exe /query /status 2>&1
        foreach ($line in @($timeOutput)) {
            if ($null -ne $line -and $line.ToString().Trim().Length -gt 0) {
                Write-LabLog -Level INFO -Message ('[W32TM] {0}' -f $line.ToString())
            }
        }
        Add-LabCheck -Name 'Time service status' -Status 'INFO' -Detail 'See W32TM output in the log.'
    }
    catch {
        Add-LabCheck -Name 'Time service status' -Status 'WARN' -Detail 'w32tm could not be queried.'
    }

    $firewall = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue)
    $firewallEnabled = @($firewall | Where-Object { $_.Enabled -eq $true })
    Add-LabCheck -Name 'Firewall profile state' -Status 'INFO' -Detail ($(if ($firewallEnabled.Count -eq 0) { 'All profiles disabled; this script does not change firewall policy' } else { 'Enabled: ' + (($firewallEnabled | ForEach-Object { $_.Name }) -join ', ') }))

    $result = Write-LabCheckSummary
    if ($result -eq 'FAIL') {
        Write-LabLog -Level ERROR -Message 'AD DS/DNS verification FAILED. Review the failed checks and the script log before continuing to DHCP.'
        exit 2
    }

    Write-LabLog -Level SUCCESS -Message 'AD DS/DNS verification passed. Next: 04-Install-DHCP.ps1.'
    exit 0
}
catch {
    $message = $_.Exception.Message
    try { Write-LabLog -Level ERROR -Message ('FATAL: {0}' -f $message) } catch { Write-Host ('FATAL: {0}' -f $message) -ForegroundColor Red }
    exit 2
}
