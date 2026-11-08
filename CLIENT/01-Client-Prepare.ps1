<#
.SYNOPSIS
    CLIENT 01 - Prepare WRK01: static IPv4/DNS for the join phase and rename.

.DESCRIPTION
    Target machine : WRK01 (Windows 10 Pro), baseline DESKTOP-JE6RBJV.
    Changes made   : static IPv4 192.168.63.10/24, no default gateway,
                     DNS 192.168.63.2, computer name WRK01.
    Safety         : idempotent for the known Lab 1 baseline and the target state.
                     Stops on unexpected name/IP or if the client is already domain-joined.
                     The static address is TEMPORARY; 03-Configure-DHCP.ps1 switches
                     the adapter to DHCP after the domain join.

.PARAMETER Force
    Allows continuing when the current computer name or IPv4 is not the documented
    Lab 1 baseline. Use only when you understand the current state.

.NOTES
    Reboot required : YES, when the computer is renamed. The script never reboots.
    Expected output : first run -> exit code 3 (manual reboot required).
                      after reboot -> exit code 0.
    Exit codes      : 0 success/no change, 1 precondition failed, 2 operation failed,
                      3 manual reboot required.
    After this step : reboot manually from the VMware console, then run 02-Join-Domain.ps1.
#>
[CmdletBinding()]
param(
    [switch]$Force
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
    Start-LabSession -ScriptName '01-Client-Prepare' -LogDirectory $config.Paths.LogDirectory

    $client = $config.Client
    $domain = $config.Domain

    Write-LabLog -Level STEP -Message '=== CLIENT 01 - Prepare static IPv4/DNS and rename ==='

    $state = Get-LabComputerState
    Write-LabComputerState -State $state

    $pending = Get-LabPendingReboot
    if ($pending.Pending) {
        foreach ($reason in $pending.Reasons) {
            Write-LabLog -Level ERROR -Message ('Pending reboot reason: {0}' -f $reason)
        }
        Write-LabLog -Level ERROR -Message 'A reboot is already pending. Reboot this VM manually from the VMware console, then run 01 again.'
        exit 3
    }

    if ($state.PartOfDomain) {
        if ($state.Domain -eq $domain.DnsName) {
            if ($state.Name -ne $client.Name) {
                Write-LabLog -Level ERROR -Message ('Client is joined to {0} but the computer name is {1}, expected {2}. No changes made; repair the name or restore Snapshot Lab 1.' -f $domain.DnsName, $state.Name, $client.Name)
                exit 1
            }
            Write-LabLog -Level INFO -Message ('Client is already joined to {0}. Preparation changes are skipped.' -f $domain.DnsName)
            Add-LabCheck -Name 'Client preparation' -Status 'INFO' -Detail 'Already domain-joined; continue with 03-Configure-DHCP.ps1 / 04-Verify-Client.ps1.'
            [void](Write-LabCheckSummary)
            exit 0
        }
        Write-LabLog -Level ERROR -Message ('Client is joined to unexpected domain {0}. No changes made; manual decision required.' -f $state.Domain)
        exit 1
    }

    $needRename = $false
    if ($state.Name -eq $client.Name) {
        Write-LabLog -Level INFO -Message ('Computer name is already {0}; rename skipped.' -f $client.Name)
    }
    elseif ($state.Name -eq $client.BaselineName) {
        $needRename = $true
    }
    elseif ($Force) {
        Write-LabLog -Level WARN -Message ('Unexpected computer name {0}; -Force supplied. It will be renamed to {1}.' -f $state.Name, $client.Name)
        $needRename = $true
    }
    else {
        Write-LabLog -Level ERROR -Message ('Unexpected computer name {0}. Expected {1} or {2}. No changes made. Use -Force only if intentional.' -f $state.Name, $client.BaselineName, $client.Name)
        exit 1
    }

    $adapter = Get-LabNetworkAdapter -MacAddress $client.MacAddress -KnownIPs @($client.BaselineIPAddress, $client.StaticIPAddress)
    Write-LabLog -Level INFO -Message ('Target adapter: {0} | MAC {1} | ifIndex {2}' -f $adapter.Name, $adapter.MacAddress, $adapter.ifIndex)

    $interfaceInfo = Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop
    if ($interfaceInfo.Dhcp -eq 'Enabled') {
        Write-LabLog -Level WARN -Message 'The target adapter is DHCP-enabled (for example the Lab 1 VMware lease). It will be converted to the temporary static 192.168.63.10 for the join phase.'
    }

    $addresses = @(Get-LabInterfaceAddresses -InterfaceIndex $adapter.ifIndex)
    $targetAddress = @($addresses | Where-Object { $_.IPAddress -eq $client.StaticIPAddress -and $_.PrefixLength -eq $client.PrefixLength })
    $unexpectedAddresses = @($addresses | Where-Object {
            $_.IPAddress -ne $client.StaticIPAddress -and
            $_.IPAddress -ne $client.BaselineIPAddress -and
            $_.PrefixOrigin -ne 'WellKnown' -and
            -not $_.IPAddress.StartsWith('169.254.')
        })

    if ($unexpectedAddresses.Count -gt 0 -and -not $Force) {
        $list = ($unexpectedAddresses | ForEach-Object { '{0}/{1}' -f $_.IPAddress, $_.PrefixLength }) -join ', '
        Write-LabLog -Level ERROR -Message ('Unexpected IPv4 address(es) on the target adapter: {0}. Expected {1} or {2}. No changes made. Use -Force only if intentional.' -f $list, $client.BaselineIPAddress, $client.StaticIPAddress)
        exit 1
    }

    if ($targetAddress.Count -eq 0 -or ($unexpectedAddresses.Count -gt 0 -and $Force)) {
        Set-LabStaticIPv4 -InterfaceIndex $adapter.ifIndex -IPAddress $client.StaticIPAddress -PrefixLength $client.PrefixLength -Gateway $client.Gateway -DnsServers $client.DnsServers
    }
    else {
        Write-LabLog -Level INFO -Message ('IPv4 {0}/{1} is already configured.' -f $client.StaticIPAddress, $client.PrefixLength)

        $dnsObject = Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $dnsNow = @()
        if ($dnsObject) { $dnsNow = @($dnsObject.ServerAddresses) }
        $expectedDns = @($client.DnsServers)
        if ((($dnsNow | Sort-Object) -join ',') -ne (($expectedDns | Sort-Object) -join ',')) {
            Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $expectedDns -ErrorAction Stop
            Write-LabLog -Level INFO -Message ('DNS client servers set to: {0}' -f ($expectedDns -join ', '))
        }
        else {
            Write-LabLog -Level INFO -Message ('DNS client servers already set to: {0}' -f ($expectedDns -join ', '))
        }

        if (-not $client.Gateway) {
            Remove-LabDefaultRoute -InterfaceIndex $adapter.ifIndex
        }
    }

    if ($needRename) {
        Write-LabLog -Level STEP -Message ('Renaming computer {0} -> {1}.' -f $state.Name, $client.Name)
        Rename-Computer -NewName $client.Name -Force -PassThru -ErrorAction Stop | Out-Null
        Write-LabLog -Level SUCCESS -Message 'Rename staged successfully. A manual reboot is required.'
    }

    $finalAddresses = @(Get-LabInterfaceAddresses -InterfaceIndex $adapter.ifIndex)
    $finalTarget = @($finalAddresses | Where-Object { $_.IPAddress -eq $client.StaticIPAddress -and $_.PrefixLength -eq $client.PrefixLength -and $_.PrefixOrigin -ne 'Dhcp' })
    $finalUnexpected = @($finalAddresses | Where-Object {
            $_.IPAddress -ne $client.StaticIPAddress -and
            $_.PrefixOrigin -ne 'WellKnown' -and
            -not $_.IPAddress.StartsWith('169.254.')
        })
    $ipOk = ($finalTarget.Count -eq 1 -and $finalUnexpected.Count -eq 0)
    Add-LabCheck -Name ('Static IPv4 {0}/{1}' -f $client.StaticIPAddress, $client.PrefixLength) -Status ($(if ($ipOk) { 'PASS' } else { 'FAIL' })) -Detail (($finalAddresses | ForEach-Object { '{0}/{1} ({2})' -f $_.IPAddress, $_.PrefixLength, $_.PrefixOrigin }) -join ', ')

    $dnsObject = Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    $dnsNow = @()
    if ($dnsObject) { $dnsNow = @($dnsObject.ServerAddresses) }
    $dnsOk = ((($dnsNow | Sort-Object) -join ',') -eq ((@($client.DnsServers) | Sort-Object) -join ','))
    Add-LabCheck -Name 'DNS client configuration' -Status ($(if ($dnsOk) { 'PASS' } else { 'FAIL' })) -Detail ($dnsNow -join ', ')

    $defaultRoutes = @(Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
    Add-LabCheck -Name 'No default gateway (by design)' -Status ($(if ($defaultRoutes.Count -eq 0) { 'PASS' } else { 'FAIL' })) -Detail ('Default routes: {0}' -f $defaultRoutes.Count)

    $activeName = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -Name ComputerName -ErrorAction Stop).ComputerName
    $stagedName = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -Name ComputerName -ErrorAction Stop).ComputerName
    Add-LabCheck -Name 'Computer name target' -Status ($(if ($stagedName -eq $client.Name) { 'PASS' } else { 'FAIL' })) -Detail ('active={0}, staged={1}' -f $activeName, $stagedName)

    $vmTools = Get-Service -Name VMTools -ErrorAction SilentlyContinue
    Add-LabCheck -Name 'VMware Tools service' -Status ($(if ($vmTools -and $vmTools.Status -eq 'Running') { 'PASS' } else { 'WARN' })) -Detail ($(if ($vmTools) { $vmTools.Status.ToString() } else { 'VMTools service not found' }))

    $pendingAfter = Get-LabPendingReboot
    foreach ($reason in $pendingAfter.Reasons) {
        Write-LabLog -Level INFO -Message ('Reboot reason: {0}' -f $reason)
    }

    [void](Write-LabCheckSummary)

    if (-not $ipOk -or -not $dnsOk -or $defaultRoutes.Count -gt 0 -or $stagedName -ne $client.Name) {
        exit 2
    }

    if ($pendingAfter.Pending) {
        Write-LabLog -Level WARN -Message 'MANUAL STEP REQUIRED: reboot this VM from the VMware console now. After reboot, verify hostname is WRK01 and run 02-Join-Domain.ps1.'
        exit 3
    }

    Write-LabLog -Level SUCCESS -Message 'Client preparation is complete. No reboot is pending; run 02-Join-Domain.ps1.'
    exit 0
}
catch {
    $message = $_.Exception.Message
    try { Write-LabLog -Level ERROR -Message ('FATAL: {0}' -f $message) } catch { Write-Host ('FATAL: {0}' -f $message) -ForegroundColor Red }
    exit 2
}
