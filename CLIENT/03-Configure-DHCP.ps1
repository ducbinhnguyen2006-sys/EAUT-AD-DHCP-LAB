<#
.SYNOPSIS
    CLIENT 03 - Switch WRK01 from the temporary static address to DHCP.

.DESCRIPTION
    Target machine : WRK01 (Windows 10 Pro), domain-joined to binhnd363.edu.vn.
    Changes made   : enables DHCP on the physical adapter, renews the lease, and lets
                     DHCP options provide DNS 192.168.63.2 and the DNS domain.
                     No default gateway is provided by design.
    Safety         : if a valid lease in 192.168.63.100-200 already exists, the script
                     skips changes (unless -Renew). If no lease is obtained, or the lease
                     does not come from 192.168.63.2 with DNS 192.168.63.2, it restores
                     the temporary static 192.168.63.10 / DNS 192.168.63.2 so the client
                     remains manageable, and exits with failure.

.PARAMETER Renew
    Forces a release/renew even when a valid lease already exists.

.NOTES
    Reboot required : NO. A logoff/logon may be needed for new group policy settings.
    Expected output : RESULT: PASS and exit code 0 with a lease in 192.168.63.100-200.
    Exit codes      : 0 success/no change, 1 precondition failed, 2 operation failed,
                      3 manual reboot required.
    After this step : run 04-Verify-Client.ps1, then rerun SERVER 06 for lease evidence.
#>
[CmdletBinding()]
param(
    [switch]$Renew
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
    Start-LabSession -ScriptName '03-Configure-DHCP' -LogDirectory $config.Paths.LogDirectory

    $server = $config.Server
    $client = $config.Client
    $domain = $config.Domain
    $dhcp = $config.Dhcp
    $scopePrefix = Get-LabScopeId -IPAddress $dhcp.StartRange -PrefixLength $server.PrefixLength
    $scopeStartNumber = ConvertTo-LabUInt32 -IPAddress $dhcp.StartRange
    $scopeEndNumber = ConvertTo-LabUInt32 -IPAddress $dhcp.EndRange

    Write-LabLog -Level STEP -Message '=== CLIENT 03 - Configure DHCP ==='

    $state = Get-LabComputerState
    Write-LabComputerState -State $state

    $pending = Get-LabPendingReboot
    if ($pending.Pending) {
        foreach ($reason in $pending.Reasons) {
            Write-LabLog -Level ERROR -Message ('Pending reboot reason: {0}' -f $reason)
        }
        Write-LabLog -Level ERROR -Message 'A reboot is pending. Reboot manually and run 03 again. No changes made.'
        exit 3
    }

    if (-not $state.PartOfDomain -or $state.Domain -ne $domain.DnsName) {
        Write-LabLog -Level ERROR -Message ('Client is not joined to {0}. Run 01 and 02 first. No changes made.' -f $domain.DnsName)
        exit 1
    }

    $secure = $false
    try { $secure = Test-ComputerSecureChannel -ErrorAction Stop } catch { $secure = $false }
    if (-not $secure) {
        Write-LabLog -Level ERROR -Message 'The machine secure channel is not valid. Do not switch to DHCP yet; resolve the domain join (02/04) first. No changes made.'
        exit 1
    }

    $adapter = Get-LabNetworkAdapter -MacAddress $client.MacAddress -KnownIPs @($client.StaticIPAddress, $client.BaselineIPAddress)
    $interfaceInfo = Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop
    $dhcpState = Get-LabDhcpState -InterfaceIndex $adapter.ifIndex

    $existingLease = $null
    foreach ($address in @($dhcpState.Addresses)) {
        $number = ConvertTo-LabUInt32 -IPAddress $address.IPAddress
        if ($number -ge $scopeStartNumber -and $number -le $scopeEndNumber) {
            $existingLease = $address
            break
        }
    }

    $leaseAddress = $null
    if ($interfaceInfo.Dhcp -eq 'Enabled' -and $existingLease -and -not $Renew) {
        Write-LabLog -Level INFO -Message ('Adapter already uses DHCP with lease {0}/{1} inside the scope.' -f $existingLease.IPAddress, $existingLease.PrefixLength)
        $leaseAddress = $existingLease
    }
    else {
        if ($Renew) {
            Write-LabLog -Level STEP -Message ('Releasing the current lease on adapter {0} (-Renew).' -f $adapter.Name)
            Invoke-LabIpconfig -Action release -InterfaceAlias $adapter.Name -InterfaceIndex $adapter.ifIndex
        }

        Write-LabLog -Level STEP -Message 'Enabling DHCP and requesting a lease.'
        $leaseAddress = Enable-LabDhcpClient -InterfaceIndex $adapter.ifIndex -ExpectedPrefix $scopePrefix -ExpectedPrefixLength $server.PrefixLength -TimeoutSeconds 90
    }

    if (-not $leaseAddress) {
        Add-LabCheck -Name 'DHCP lease' -Status 'FAIL' -Detail 'No lease in 192.168.63.100-200 was obtained within 90 seconds.'
        Write-LabLog -Level WARN -Message 'Restoring the temporary static 192.168.63.10 / DNS 192.168.63.2 so the VM remains manageable for troubleshooting.'
        Set-LabStaticIPv4 -InterfaceIndex $adapter.ifIndex -IPAddress $client.StaticIPAddress -PrefixLength $client.PrefixLength -Gateway $client.Gateway -DnsServers $client.DnsServers
        Add-LabCheck -Name 'Fallback static configuration' -Status 'WARN' -Detail ('Restored {0}/{1}, DNS {2}.' -f $client.StaticIPAddress, $client.PrefixLength, ($client.DnsServers -join ', '))
        Write-LabLog -Level ERROR -Message 'DHCP failed. Check: server 04/05 PASS, DHCP authorized, scope Active, VMware DHCP OFF on VMnet3, and no firewall blocking UDP 67/68.'
        [void](Write-LabCheckSummary)
        exit 2
    }

    $dhcpServerAddress = $null
    for ($i = 0; $i -lt 10; $i++) {
        $dhcpServerAddress = Get-LabDhcpServerAddress -InterfaceIndex $adapter.ifIndex
        if ($dhcpServerAddress) { break }
        Start-Sleep -Seconds 1
    }
    $dhcpServerOk = ($dhcpServerAddress -eq $server.IPAddress)
    Add-LabCheck -Name 'DHCP server identity' -Status ($(if ($dhcpServerOk) { 'PASS' } else { 'FAIL' })) -Detail ('DHCP server={0}, expected={1}' -f $dhcpServerAddress, $server.IPAddress)

    $dnsOk = $false
    for ($i = 0; $i -lt 20; $i++) {
        $dnsObject = Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $dnsNow = @()
        if ($dnsObject) { $dnsNow = @($dnsObject.ServerAddresses) }
        if (((($dnsNow | Sort-Object) -join ',') -eq $server.IPAddress)) {
            $dnsOk = $true
            break
        }
        Start-Sleep -Seconds 2
    }

    if (-not $dhcpServerOk -or -not $dnsOk) {
        Write-LabLog -Level ERROR -Message 'The lease did not come from the expected DHCP server or DHCP did not provide the expected DNS server.'
        if (-not $dnsOk) {
            Add-LabCheck -Name 'DNS from DHCP (192.168.63.2)' -Status 'FAIL' -Detail ($dnsNow -join ', ')
        }
        Write-LabLog -Level WARN -Message 'Restoring the temporary static configuration so the client remains manageable.'
        Set-LabStaticIPv4 -InterfaceIndex $adapter.ifIndex -IPAddress $client.StaticIPAddress -PrefixLength $client.PrefixLength -Gateway $client.Gateway -DnsServers $client.DnsServers
        Add-LabCheck -Name 'Fallback static configuration' -Status 'WARN' -Detail ('Restored {0}/{1}, DNS {2}.' -f $client.StaticIPAddress, $client.PrefixLength, ($client.DnsServers -join ', '))
        Write-LabLog -Level ERROR -Message 'Verify that VMware DHCP is disabled on VMnet3 and that EAUT-SRV12 is the only DHCP server on the lab network.'
        [void](Write-LabCheckSummary)
        exit 2
    }

    $finalInterface = Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop
    $finalAddresses = @(Get-LabInterfaceAddresses -InterfaceIndex $adapter.ifIndex)
    $finalLease = @($finalAddresses | Where-Object {
            $number = ConvertTo-LabUInt32 -IPAddress $_.IPAddress
            $number -ge $scopeStartNumber -and $number -le $scopeEndNumber -and $_.PrefixOrigin -eq 'Dhcp'
        }) | Select-Object -First 1

    $dnsObject = Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    $dnsNow = @()
    if ($dnsObject) { $dnsNow = @($dnsObject.ServerAddresses) }
    $dnsOk = ((($dnsNow | Sort-Object) -join ',') -eq $server.IPAddress)
    $defaultRoutes = @(Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
    $dnsSuffix = ''
    for ($i = 0; $i -lt 10; $i++) {
        $dnsSuffix = Get-LabConnectionDnsSuffix -InterfaceIndex $adapter.ifIndex
        if ($dnsSuffix -eq $domain.DnsName) { break }
        Start-Sleep -Seconds 2
    }

    $leftoverStatic = @($finalAddresses | Where-Object { $_.IPAddress -eq $client.StaticIPAddress })

    Add-LabCheck -Name 'DHCP enabled on adapter' -Status ($(if ($finalInterface.Dhcp -eq 'Enabled') { 'PASS' } else { 'FAIL' })) -Detail $finalInterface.Dhcp.ToString()
    Add-LabCheck -Name 'DHCP lease inside scope' -Status ($(if ($finalLease) { 'PASS' } else { 'FAIL' })) -Detail ($(if ($finalLease) { '{0}/{1} (origin {2})' -f $finalLease.IPAddress, $finalLease.PrefixLength, $finalLease.PrefixOrigin } else { 'no in-scope DHCP IPv4' }))
    Add-LabCheck -Name 'Temporary static address removed' -Status ($(if ($leftoverStatic.Count -eq 0) { 'PASS' } else { 'FAIL' })) -Detail ($(if ($leftoverStatic.Count -eq 0) { $client.StaticIPAddress + ' is absent' } else { $client.StaticIPAddress + ' is still configured' }))
    Add-LabCheck -Name 'DNS from DHCP (192.168.63.2)' -Status ($(if ($dnsOk) { 'PASS' } else { 'FAIL' })) -Detail ($dnsNow -join ', ')
    Add-LabCheck -Name 'DHCP DNS suffix' -Status ($(if ($dnsSuffix -eq $domain.DnsName) { 'PASS' } else { 'FAIL' })) -Detail ('connection suffix={0}, expected={1}' -f $dnsSuffix, $domain.DnsName)
    Add-LabCheck -Name 'Default gateway absent (by design)' -Status ($(if ($defaultRoutes.Count -eq 0) { 'PASS' } else { 'FAIL' })) -Detail ('Default routes: {0}' -f $defaultRoutes.Count)

    $secureAfter = $false
    try { $secureAfter = Test-ComputerSecureChannel -ErrorAction Stop } catch { $secureAfter = $false }
    Add-LabCheck -Name 'Domain secure channel after DHCP' -Status ($(if ($secureAfter) { 'PASS' } else { 'WARN' })) -Detail ($(if ($secureAfter) { 'Valid' } else { 'Recheck after logoff/logon or in 04' }))

    Write-LabLog -Level STEP -Message 'ipconfig /all output:'
    $ipconfigOutput = & ipconfig.exe /all 2>&1
    foreach ($line in @($ipconfigOutput)) {
        Write-LabLog -Level INFO -Message ('[IPCONFIG] {0}' -f $line.ToString())
    }

    $result = Write-LabCheckSummary
    if ($result -eq 'FAIL') {
        Write-LabLog -Level ERROR -Message 'DHCP client verification failed. Review the failed checks.'
        exit 2
    }

    Write-LabLog -Level SUCCESS -Message 'Client now uses DHCP. Next: 04-Verify-Client.ps1, then rerun SERVER 06-Verify-Server.ps1 for the lease record.'
    exit 0
}
catch {
    $message = $_.Exception.Message
    try { Write-LabLog -Level ERROR -Message ('FATAL: {0}' -f $message) } catch { Write-Host ('FATAL: {0}' -f $message) -ForegroundColor Red }
    exit 2
}
