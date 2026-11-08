<#
.SYNOPSIS
    CLIENT 04 - Verify WRK01 domain membership, DHCP lease, DNS and DC reachability (read-only).

.DESCRIPTION
    Target machine : WRK01 (Windows 10 Pro), after 01-03 and reboots.
    Changes made   : NONE. This script only inspects and reports.
    Checks         : hostname, domain membership, secure channel, DHCP lease/origin in
                     192.168.63.100-200, DNS server 192.168.63.2, DNS resolution of the
                     AD SRV record and DC name, SYSVOL/NETLOGON, DC TCP ports, time offset,
                     firewall profiles, VMware Tools, pending reboot.

.NOTES
    Reboot required : NO.
    Expected output : RESULT: PASS and exit code 0.
    Exit codes      : 0 success, 2 one or more checks failed.
    Safe to rerun   : YES.
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
    Start-LabSession -ScriptName '04-Verify-Client' -LogDirectory $config.Paths.LogDirectory

    $server = $config.Server
    $client = $config.Client
    $domain = $config.Domain
    $dhcp = $config.Dhcp
    $serverFqdn = '{0}.{1}' -f $server.Name, $domain.DnsName
    $scopeStartNumber = ConvertTo-LabUInt32 -IPAddress $dhcp.StartRange
    $scopeEndNumber = ConvertTo-LabUInt32 -IPAddress $dhcp.EndRange

    Write-LabLog -Level STEP -Message '=== CLIENT 04 - Verify client (read-only) ==='

    $state = Get-LabComputerState
    Write-LabComputerState -State $state

    Add-LabCheck -Name 'Computer name WRK01' -Status ($(if ($state.Name -eq $client.Name) { 'PASS' } else { 'FAIL' })) -Detail $state.Name
    Add-LabCheck -Name 'Domain membership' -Status ($(if ($state.PartOfDomain -and $state.Domain -eq $domain.DnsName) { 'PASS' } else { 'FAIL' })) -Detail ('Domain={0}, PartOfDomain={1}' -f $state.Domain, $state.PartOfDomain)

    $secure = $false
    try { $secure = Test-ComputerSecureChannel -ErrorAction Stop } catch { $secure = $false }
    Add-LabCheck -Name 'Machine secure channel' -Status ($(if ($secure) { 'PASS' } else { 'FAIL' })) -Detail ($(if ($secure) { 'Valid' } else { 'Invalid - repair or rejoin' }))

    $adapter = Get-LabNetworkAdapter -MacAddress $client.MacAddress -KnownIPs @($client.StaticIPAddress, $client.BaselineIPAddress)
    $interfaceInfo = Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop
    $addresses = @(Get-LabInterfaceAddresses -InterfaceIndex $adapter.ifIndex)
    $lease = @($addresses | Where-Object {
            $number = ConvertTo-LabUInt32 -IPAddress $_.IPAddress
            $number -ge $scopeStartNumber -and $number -le $scopeEndNumber -and $_.PrefixOrigin -eq 'Dhcp'
        }) | Select-Object -First 1

    $leftoverStatic = @($addresses | Where-Object { $_.IPAddress -eq $client.StaticIPAddress })

    Add-LabCheck -Name 'Adapter uses DHCP' -Status ($(if ($interfaceInfo.Dhcp -eq 'Enabled') { 'PASS' } else { 'FAIL' })) -Detail $interfaceInfo.Dhcp.ToString()
    Add-LabCheck -Name 'DHCP lease in 192.168.63.100-200' -Status ($(if ($lease) { 'PASS' } else { 'FAIL' })) -Detail ($(if ($lease) { '{0}/{1} origin={2}' -f $lease.IPAddress, $lease.PrefixLength, $lease.PrefixOrigin } else { 'no in-scope DHCP IPv4 on {0}' -f $adapter.Name }))
    Add-LabCheck -Name 'Temporary static address removed' -Status ($(if ($leftoverStatic.Count -eq 0) { 'PASS' } else { 'FAIL' })) -Detail ($(if ($leftoverStatic.Count -eq 0) { $client.StaticIPAddress + ' is absent' } else { $client.StaticIPAddress + ' is still configured' }))

    $dhcpServerAddress = Get-LabDhcpServerAddress -InterfaceIndex $adapter.ifIndex
    Add-LabCheck -Name 'DHCP server identity' -Status ($(if ($dhcpServerAddress -eq $server.IPAddress) { 'PASS' } else { 'FAIL' })) -Detail ('DHCP server={0}, expected={1}' -f $dhcpServerAddress, $server.IPAddress)

    $dnsObject = Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    $dnsNow = @()
    if ($dnsObject) { $dnsNow = @($dnsObject.ServerAddresses) }
    Add-LabCheck -Name 'DNS server is 192.168.63.2' -Status ($(if (((($dnsNow | Sort-Object) -join ',') -eq $server.IPAddress)) { 'PASS' } else { 'FAIL' })) -Detail ($dnsNow -join ', ')

    $primarySuffix = ''
    try {
        $primarySuffix = [string](Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -Name 'NV Domain' -ErrorAction Stop).'NV Domain'
    }
    catch {
        $primarySuffix = ''
    }
    $searchList = @()
    try {
        $searchList = @((Get-DnsClientGlobalSetting -ErrorAction Stop).SuffixSearchList)
    }
    catch {
        $searchList = @()
    }
    $dnsSuffix = Get-LabConnectionDnsSuffix -InterfaceIndex $adapter.ifIndex
    Add-LabCheck -Name 'DNS suffix context' -Status 'INFO' -Detail ('primary={0}, connection-specific={1}, search-list={2}' -f $primarySuffix, $dnsSuffix, ($searchList -join ', '))
    Add-LabCheck -Name 'DHCP DNS suffix' -Status ($(if ($dnsSuffix -eq $domain.DnsName) { 'PASS' } else { 'FAIL' })) -Detail ('connection-specific suffix={0}, expected={1}' -f $dnsSuffix, $domain.DnsName)

    $defaultRoutes = @(Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
    Add-LabCheck -Name 'Default gateway absent (by design)' -Status ($(if ($defaultRoutes.Count -eq 0) { 'PASS' } else { 'FAIL' })) -Detail ('Default routes: {0}' -f $defaultRoutes.Count)

    try {
        $srvAnswers = @(Resolve-DnsName -Name ('_ldap._tcp.dc._msdcs.{0}' -f $domain.DnsName) -Type SRV -DnsOnly -ErrorAction Stop)
        $srvTargets = @($srvAnswers | Where-Object { $_.NameTarget } | ForEach-Object { $_.NameTarget.TrimEnd('.').ToLowerInvariant() })
        $srvOk = @($srvTargets | Where-Object { $_ -eq $serverFqdn.ToLowerInvariant() }).Count -gt 0
        Add-LabCheck -Name 'DC SRV record resolves' -Status ($(if ($srvOk) { 'PASS' } else { 'FAIL' })) -Detail ($srvTargets -join ', ')
    }
    catch {
        Add-LabCheck -Name 'DC SRV record resolves' -Status 'FAIL' -Detail $_.Exception.Message
    }

    try {
        $dcRecord = @(Resolve-DnsName -Name $serverFqdn -Type A -DnsOnly -ErrorAction Stop | Where-Object { $_.IPAddress })
        $dcOk = @($dcRecord | Where-Object { $_.IPAddress -eq $server.IPAddress }).Count -gt 0
        Add-LabCheck -Name 'DC name resolves to 192.168.63.2' -Status ($(if ($dcOk) { 'PASS' } else { 'FAIL' })) -Detail (($dcRecord | ForEach-Object { $_.IPAddress }) -join ', ')
    }
    catch {
        Add-LabCheck -Name 'DC name resolves to 192.168.63.2' -Status 'FAIL' -Detail $_.Exception.Message
    }

    try {
        $domainRecord = @(Resolve-DnsName -Name $domain.DnsName -Type A -DnsOnly -ErrorAction Stop | Where-Object { $_.IPAddress })
        Add-LabCheck -Name 'Domain name resolves' -Status ($(if ($domainRecord.Count -gt 0) { 'PASS' } else { 'WARN' })) -Detail (($domainRecord | ForEach-Object { $_.IPAddress }) -join ', ')
    }
    catch {
        Add-LabCheck -Name 'Domain name resolves' -Status 'WARN' -Detail $_.Exception.Message
    }

    $sysvolOk = (Test-Path -LiteralPath ('\\{0}\SYSVOL\{1}' -f $server.Name, $domain.DnsName)) -and (Test-Path -LiteralPath ('\\{0}\NETLOGON' -f $server.Name))
    Add-LabCheck -Name 'SYSVOL/NETLOGON reachable' -Status ($(if ($sysvolOk) { 'PASS' } else { 'FAIL' })) -Detail ('\\{0}\SYSVOL, \\{0}\NETLOGON' -f $server.Name)

    $portResults = @{}
    foreach ($port in @(53, 88, 389, 445, 135)) {
        $portResults[$port] = Test-LabTcpPort -ComputerName $server.IPAddress -Port $port
    }
    $portsOk = @($portResults.Values | Where-Object { $_ -eq $false }).Count -eq 0
    Add-LabCheck -Name 'DC TCP ports (53,88,389,445,135)' -Status ($(if ($portsOk) { 'PASS' } else { 'FAIL' })) -Detail (($portResults.Keys | Sort-Object | ForEach-Object { '{0}={1}' -f $_, $portResults[$_] }) -join ', ')

    $nltestOk = $false
    try {
        $nltestOutput = & nltest.exe ('/sc_query:{0}' -f $domain.DnsName) 2>&1
        $nltestOk = ($LASTEXITCODE -eq 0)
        Add-LabCheck -Name 'nltest secure channel query' -Status ($(if ($nltestOk) { 'PASS' } else { 'FAIL' })) -Detail (($nltestOutput | ForEach-Object { $_.ToString().Trim() }) -join ' | ')
    }
    catch {
        Add-LabCheck -Name 'nltest secure channel query' -Status 'WARN' -Detail $_.Exception.Message
    }

    $timeOk = $null
    $timeDetail = 'w32tm output could not be parsed'
    try {
        $w32Output = & w32tm.exe /stripchart ('/computer:{0}' -f $serverFqdn) /samples:1 /dataonly 2>&1
        $text = ($w32Output | ForEach-Object { $_.ToString() }) -join ' '
        $match = [regex]::Match($text, '([+-]?\d+(?:[.,]\d+)?)s\b')
        if ($match.Success) {
            $offset = [double](($match.Groups[1].Value) -replace ',', '.')
            $timeOk = ([math]::Abs($offset) -lt 300)
            $timeDetail = ('offset {0:N3}s (limit 300s)' -f $offset)
        }
    }
    catch {
        $timeDetail = $_.Exception.Message
    }
    Add-LabCheck -Name 'Time offset vs DC' -Status ($(if ($null -eq $timeOk) { 'WARN' } elseif ($timeOk) { 'PASS' } else { 'FAIL' })) -Detail $timeDetail

    $firewall = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue)
    $firewallEnabled = @($firewall | Where-Object { $_.Enabled -eq $true })
    Add-LabCheck -Name 'Firewall profile state' -Status 'INFO' -Detail ($(if ($firewallEnabled.Count -eq 0) { 'All profiles disabled; this script does not change firewall policy' } else { 'Enabled: ' + (($firewallEnabled | ForEach-Object { $_.Name }) -join ', ') }))

    $vmTools = Get-Service -Name VMTools -ErrorAction SilentlyContinue
    Add-LabCheck -Name 'VMware Tools service' -Status ($(if ($vmTools -and $vmTools.Status -eq 'Running') { 'PASS' } else { 'WARN' })) -Detail ($(if ($vmTools) { $vmTools.Status.ToString() } else { 'VMTools service not found' }))

    $pending = Get-LabPendingReboot
    Add-LabCheck -Name 'No pending reboot' -Status ($(if ($pending.Pending) { 'WARN' } else { 'PASS' })) -Detail ($(if ($pending.Pending) { $pending.Reasons -join '; ' } else { 'none' }))

    Write-LabLog -Level STEP -Message 'ipconfig /all output:'
    $ipconfigOutput = & ipconfig.exe /all 2>&1
    foreach ($line in @($ipconfigOutput)) {
        Write-LabLog -Level INFO -Message ('[IPCONFIG] {0}' -f $line.ToString())
    }

    $result = Write-LabCheckSummary
    if ($result -eq 'FAIL') {
        Write-LabLog -Level ERROR -Message 'Client verification FAILED. Review failed checks. If DHCP is broken, rerun 03 (it restores static 192.168.63.10 on failure).'
        exit 2
    }

    Write-LabLog -Level SUCCESS -Message 'Client verification completed. Client-side evidence is ready; rerun SERVER 06 for the DHCP lease record.'
    exit 0
}
catch {
    $message = $_.Exception.Message
    try { Write-LabLog -Level ERROR -Message ('FATAL: {0}' -f $message) } catch { Write-Host ('FATAL: {0}' -f $message) -ForegroundColor Red }
    exit 2
}
