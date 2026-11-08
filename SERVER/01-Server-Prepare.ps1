<#
.SYNOPSIS
    SERVER 01 - Prepare EAUT-SRV12, configure static IPv4/DNS and rename the server.

.DESCRIPTION
    Target machine : EAUT-SRV12 (Windows Server 2019), baseline WIN-CFQCN24HB2F.
    Changes made   : static IPv4 192.168.63.2/24, no default gateway, DNS 192.168.63.2,
                     computer name EAUT-SRV12.
    Safety         : idempotent for the known Lab 1 baseline and the target state.
                     Stops on unexpected name/IP unless -Force is supplied.

.PARAMETER Force
    Allows the script to continue when the current computer name or IPv4 address is
    not the documented Lab 1 baseline. Use only when you understand the current state.

.NOTES
    Reboot required : YES, but only when the computer is renamed. The script never reboots.
    Expected output : first run with rename -> exit code 3 (manual reboot required).
                      after reboot -> exit code 0.
    Exit codes      : 0 success/no change, 1 precondition failed, 2 operation failed,
                      3 manual reboot required.
    After this step : reboot the VM manually from the VMware console, then run
                      02-Install-ADDS.ps1.
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
    Start-LabSession -ScriptName '01-Server-Prepare' -LogDirectory $config.Paths.LogDirectory

    $server = $config.Server
    Write-LabLog -Level STEP -Message '=== SERVER 01 - Prepare, static IPv4, rename ==='

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
        Write-LabLog -Level ERROR -Message ('Server is joined to domain {0}. Expected WORKGROUP before AD DS installation. No changes made.' -f $state.Domain)
        exit 1
    }

    $needRename = $false
    if ($state.Name -eq $server.Name) {
        Write-LabLog -Level INFO -Message ('Computer name is already {0}; rename skipped.' -f $server.Name)
    }
    elseif ($state.Name -eq $server.BaselineName) {
        $needRename = $true
    }
    elseif ($Force) {
        Write-LabLog -Level WARN -Message ('Unexpected computer name {0}; -Force supplied. It will be renamed to {1}.' -f $state.Name, $server.Name)
        $needRename = $true
    }
    else {
        Write-LabLog -Level ERROR -Message ('Unexpected computer name {0}. Expected {1} or {2}. No changes made. Use -Force only if intentional.' -f $state.Name, $server.BaselineName, $server.Name)
        exit 1
    }

    $adapter = Get-LabNetworkAdapter -MacAddress $server.MacAddress -KnownIPs @($server.BaselineIPAddress, $server.IPAddress)
    Write-LabLog -Level INFO -Message ('Target adapter: {0} | MAC {1} | ifIndex {2}' -f $adapter.Name, $adapter.MacAddress, $adapter.ifIndex)

    $addresses = @(Get-LabInterfaceAddresses -InterfaceIndex $adapter.ifIndex)
    $targetAddress = @($addresses | Where-Object { $_.IPAddress -eq $server.IPAddress -and $_.PrefixLength -eq $server.PrefixLength })
    $unexpectedAddresses = @($addresses | Where-Object {
            $_.IPAddress -ne $server.IPAddress -and
            $_.IPAddress -ne $server.BaselineIPAddress -and
            $_.PrefixOrigin -ne 'WellKnown' -and
            -not $_.IPAddress.StartsWith('169.254.')
        })

    if ($unexpectedAddresses.Count -gt 0 -and -not $Force) {
        $list = ($unexpectedAddresses | ForEach-Object { '{0}/{1}' -f $_.IPAddress, $_.PrefixLength }) -join ', '
        Write-LabLog -Level ERROR -Message ('Unexpected IPv4 address(es) on the target adapter: {0}. Expected {1} or {2}. No changes made. Use -Force only if intentional.' -f $list, $server.BaselineIPAddress, $server.IPAddress)
        exit 1
    }

    if ($targetAddress.Count -eq 0 -or ($unexpectedAddresses.Count -gt 0 -and $Force)) {
        Set-LabStaticIPv4 -InterfaceIndex $adapter.ifIndex -IPAddress $server.IPAddress -PrefixLength $server.PrefixLength -Gateway $server.Gateway -DnsServers $server.DnsServers
    }
    else {
        Write-LabLog -Level INFO -Message ('IPv4 {0}/{1} is already configured.' -f $server.IPAddress, $server.PrefixLength)

        $dnsObject = Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $dnsNow = @()
        if ($dnsObject) { $dnsNow = @($dnsObject.ServerAddresses) }
        $expectedDns = @($server.DnsServers)
        if ((($dnsNow | Sort-Object) -join ',') -ne (($expectedDns | Sort-Object) -join ',')) {
            Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $expectedDns -ErrorAction Stop
            Write-LabLog -Level INFO -Message ('DNS client servers set to: {0}' -f ($expectedDns -join ', '))
        }
        else {
            Write-LabLog -Level INFO -Message ('DNS client servers already set to: {0}' -f ($expectedDns -join ', '))
        }

        if (-not $server.Gateway) {
            Remove-LabDefaultRoute -InterfaceIndex $adapter.ifIndex
        }
    }

    if ($needRename) {
        Write-LabLog -Level STEP -Message ('Renaming computer {0} -> {1}.' -f $state.Name, $server.Name)
        Rename-Computer -NewName $server.Name -Force -PassThru -ErrorAction Stop | Out-Null
        Write-LabLog -Level SUCCESS -Message 'Rename staged successfully. A manual reboot is required.'
    }

    $finalAddresses = @(Get-LabInterfaceAddresses -InterfaceIndex $adapter.ifIndex)
    $finalTarget = @($finalAddresses | Where-Object { $_.IPAddress -eq $server.IPAddress -and $_.PrefixLength -eq $server.PrefixLength -and $_.PrefixOrigin -ne 'Dhcp' })
    $finalUnexpected = @($finalAddresses | Where-Object {
            $_.IPAddress -ne $server.IPAddress -and
            $_.PrefixOrigin -ne 'WellKnown' -and
            -not $_.IPAddress.StartsWith('169.254.')
        })
    $ipOk = ($finalTarget.Count -eq 1 -and $finalUnexpected.Count -eq 0)
    Add-LabCheck -Name ('Static IPv4 {0}/{1}' -f $server.IPAddress, $server.PrefixLength) -Status ($(if ($ipOk) { 'PASS' } else { 'FAIL' })) -Detail ('Current: {0}' -f (($finalAddresses | ForEach-Object { '{0}/{1} ({2})' -f $_.IPAddress, $_.PrefixLength, $_.PrefixOrigin }) -join ', '))

    $dnsObject = Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    $dnsNow = @()
    if ($dnsObject) { $dnsNow = @($dnsObject.ServerAddresses) }
    $dnsOk = ((($dnsNow | Sort-Object) -join ',') -eq ((@($server.DnsServers) | Sort-Object) -join ','))
    Add-LabCheck -Name 'DNS client configuration' -Status ($(if ($dnsOk) { 'PASS' } else { 'FAIL' })) -Detail ($dnsNow -join ', ')

    $defaultRoutes = @(Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
    Add-LabCheck -Name 'No default gateway (by design)' -Status ($(if ($defaultRoutes.Count -eq 0) { 'PASS' } else { 'FAIL' })) -Detail ('Default routes: {0}' -f $defaultRoutes.Count)

    $activeName = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -Name ComputerName -ErrorAction Stop).ComputerName
    $stagedName = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -Name ComputerName -ErrorAction Stop).ComputerName
    Add-LabCheck -Name 'Computer name target' -Status ($(if ($stagedName -eq $server.Name) { 'PASS' } else { 'FAIL' })) -Detail ('active={0}, staged={1}' -f $activeName, $stagedName)

    $vmTools = Get-Service -Name VMTools -ErrorAction SilentlyContinue
    Add-LabCheck -Name 'VMware Tools service' -Status ($(if ($vmTools -and $vmTools.Status -eq 'Running') { 'PASS' } else { 'WARN' })) -Detail ($(if ($vmTools) { $vmTools.Status.ToString() } else { 'VMTools service not found' }))

    $pendingAfter = Get-LabPendingReboot
    foreach ($reason in $pendingAfter.Reasons) {
        Write-LabLog -Level INFO -Message ('Reboot reason: {0}' -f $reason)
    }

    [void](Write-LabCheckSummary)

    if (-not $ipOk -or -not $dnsOk -or $defaultRoutes.Count -gt 0 -or $stagedName -ne $server.Name) {
        exit 2
    }

    if ($pendingAfter.Pending) {
        Write-LabLog -Level WARN -Message 'MANUAL STEP REQUIRED: reboot this VM from the VMware console now. After reboot, verify hostname is EAUT-SRV12 and run 02-Install-ADDS.ps1.'
        exit 3
    }

    Write-LabLog -Level SUCCESS -Message 'Server preparation is complete. No reboot is pending; run 02-Install-ADDS.ps1.'
    exit 0
}
catch {
    $message = $_.Exception.Message
    try { Write-LabLog -Level ERROR -Message ('FATAL: {0}' -f $message) } catch { Write-Host ('FATAL: {0}' -f $message) -ForegroundColor Red }
    exit 2
}
