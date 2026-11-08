<#
.SYNOPSIS
    SERVER 04 - Install the DHCP Server role and authorize it in Active Directory.

.DESCRIPTION
    Target machine : EAUT-SRV12, domain controller for binhnd363.edu.vn.
    Changes made   : installs the DHCP Server role with management tools, starts the
                     service, completes the DHCP post-install security groups and adds
                     EAUT-SRV12.binhnd363.edu.vn (192.168.63.2) to authorized DHCP servers.
    Safety         : detects an already installed role / already authorized server and
                     skips those actions. Never removes an authorization entry and never
                     deletes a scope.

.NOTES
    Reboot required : normally NO.
    Expected output : RESULT: PASS and exit code 0.
    Exit codes      : 0 success/no change, 1 precondition failed, 2 operation failed,
                      3 manual reboot required.
    After this step : run 05-Configure-DHCP.ps1.
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
    Start-LabSession -ScriptName '04-Install-DHCP' -LogDirectory $config.Paths.LogDirectory

    $server = $config.Server
    $domain = $config.Domain
    $serverFqdn = '{0}.{1}' -f $server.Name, $domain.DnsName

    Write-LabLog -Level STEP -Message '=== SERVER 04 - Install and authorize DHCP ==='

    $state = Get-LabComputerState
    Write-LabComputerState -State $state

    $pending = Get-LabPendingReboot
    if ($pending.Pending) {
        foreach ($reason in $pending.Reasons) {
            Write-LabLog -Level ERROR -Message ('Pending reboot reason: {0}' -f $reason)
        }
        Write-LabLog -Level ERROR -Message 'A reboot is pending. Reboot manually and run 04 again. No changes made.'
        exit 3
    }

    if (-not $state.PartOfDomain -or $state.DomainRole -lt 4) {
        Write-LabLog -Level ERROR -Message 'This server is not a domain controller. Complete 02 and 03 first. No changes made.'
        exit 1
    }

    if ($state.Name -ne $server.Name) {
        Write-LabLog -Level ERROR -Message ('Computer name is {0}; expected {1}. No changes made.' -f $state.Name, $server.Name)
        exit 1
    }

    $adapter = Get-LabNetworkAdapter -MacAddress $server.MacAddress -KnownIPs @($server.IPAddress, $server.BaselineIPAddress)
    $addresses = @(Get-LabInterfaceAddresses -InterfaceIndex $adapter.ifIndex)
    $ipOk = @($addresses | Where-Object { $_.IPAddress -eq $server.IPAddress -and $_.PrefixLength -eq $server.PrefixLength }).Count -eq 1
    if (-not $ipOk) {
        Write-LabLog -Level ERROR -Message ('IPv4 {0}/{1} is not configured. Run 01 and reboot first. No changes made.' -f $server.IPAddress, $server.PrefixLength)
        exit 1
    }

    Import-LabRequiredModule -Name ActiveDirectory -PrerequisiteMessage 'AD DS tools are required.'
    try {
        $adDomain = Get-ADDomain -ErrorAction Stop
    }
    catch {
        Write-LabLog -Level ERROR -Message ('AD DS is not reachable: {0}. No changes made.' -f $_.Exception.Message)
        exit 1
    }
    if ($adDomain.DNSRoot -ne $domain.DnsName) {
        Write-LabLog -Level ERROR -Message ('Unexpected AD domain {0}. No changes made.' -f $adDomain.DNSRoot)
        exit 1
    }

    Write-LabLog -Level STEP -Message 'Checking the DHCP Server role.'
    $dhcpFeature = Get-WindowsFeature -Name DHCP
    if ($dhcpFeature.InstallState.ToString() -ne 'Installed') {
        $installResult = Install-WindowsFeature -Name DHCP -IncludeManagementTools -ErrorAction Stop
        Write-LabLog -Level INFO -Message ('DHCP install: Success={0}, RestartNeeded={1}' -f $installResult.Success, $installResult.RestartNeeded)
        if (-not $installResult.Success) {
            Write-LabLog -Level ERROR -Message 'DHCP role installation reported failure. No further changes made.'
            exit 2
        }
        if ($installResult.RestartNeeded -eq 'Yes') {
            Write-LabLog -Level WARN -Message 'DHCP role installation requires a reboot. Reboot manually and run 04 again.'
            exit 3
        }
    }
    else {
        Write-LabLog -Level INFO -Message 'DHCP Server role is already installed.'
    }

    $dhcpFeature = Get-WindowsFeature -Name DHCP
    Add-LabCheck -Name 'DHCP Server role installed' -Status ($(if ($dhcpFeature.InstallState.ToString() -eq 'Installed') { 'PASS' } else { 'FAIL' })) -Detail $dhcpFeature.InstallState.ToString()

    Import-LabRequiredModule -Name DhcpServer -PrerequisiteMessage 'DHCP management tools are missing; reinstall the DHCP role with -IncludeManagementTools.'

    $service = Get-Service -Name DHCPServer -ErrorAction SilentlyContinue
    if (-not $service) {
        Add-LabCheck -Name 'DHCP service present' -Status 'FAIL' -Detail 'DHCPServer service was not found.'
        [void](Write-LabCheckSummary)
        exit 2
    }

    Set-Service -Name DHCPServer -StartupType Automatic -ErrorAction Stop
    if ($service.Status -ne 'Running') {
        Write-LabLog -Level STEP -Message 'Starting the DHCP Server service.'
        Start-Service -Name DHCPServer -ErrorAction Stop
        $null = Wait-LabCondition -Condition { (Get-Service -Name DHCPServer -ErrorAction SilentlyContinue).Status -eq 'Running' } -TimeoutSeconds 60 -IntervalSeconds 2 -Description 'DHCP service'
    }
    $service = Get-Service -Name DHCPServer
    Add-LabCheck -Name 'DHCP service running' -Status ($(if ($service.Status -eq 'Running') { 'PASS' } else { 'FAIL' })) -Detail $service.Status.ToString()

    Write-LabLog -Level STEP -Message 'Completing DHCP post-install security groups.'
    $groupsStatus = 'PASS'
    $groupsDetail = 'Completed'
    try {
        Add-DhcpServerSecurityGroup -ErrorAction Stop | Out-Null
        Write-LabLog -Level SUCCESS -Message 'DHCP security groups added.'
    }
    catch {
        $message = $_.Exception.Message
        if ($message -match 'already|exist') {
            $groupsDetail = 'Already configured'
            Write-LabLog -Level INFO -Message ('DHCP security groups already exist: {0}' -f $message)
        }
        else {
            $groupsStatus = 'WARN'
            $groupsDetail = $message
            Write-LabLog -Level WARN -Message ('DHCP post-install security group step failed: {0}. DHCP can still function; review manually.' -f $message)
        }
    }
    Add-LabCheck -Name 'DHCP post-install security groups' -Status $groupsStatus -Detail $groupsDetail

    Write-LabLog -Level STEP -Message 'Checking Active Directory authorization for DHCP.'
    $entries = @(Get-DhcpServerInDC -ErrorAction Stop)
    $mine = @($entries | Where-Object { ([string]$_.IPAddress) -eq $server.IPAddress })

    $authorizedOk = $false
    $authorizationNameMismatch = $false
    $newlyAuthorized = $false
    if ($mine.Count -gt 0) {
        $authorizedName = [string]$mine[0].DnsName
        if ($authorizedName.TrimEnd('.') -eq $serverFqdn.TrimEnd('.')) {
            Write-LabLog -Level INFO -Message ('DHCP server is already authorized as {0} ({1}).' -f $authorizedName, $server.IPAddress)
            $authorizedOk = $true
        }
        else {
            Write-LabLog -Level WARN -Message ('DHCP server is authorized for IP {0} under a different DNS name: {1}. No change made; review manually.' -f $server.IPAddress, $authorizedName)
            $authorizedOk = $true
            $authorizationNameMismatch = $true
        }
    }
    else {
        $sameName = @($entries | Where-Object { ([string]$_.DnsName).TrimEnd('.') -eq $serverFqdn.TrimEnd('.') })
        if ($sameName.Count -gt 0) {
            Write-LabLog -Level ERROR -Message ('Authorization entry for {0} exists with a different IP: {1}. No automatic change. Remove it manually with Remove-DhcpServerInDC -IPAddress {1} and rerun 04.' -f $serverFqdn, ([string]$sameName[0].IPAddress))
            exit 1
        }

        $stale = @($entries | Where-Object { ([string]$_.IPAddress) -eq $server.BaselineIPAddress })
        if ($stale.Count -gt 0) {
            Write-LabLog -Level ERROR -Message ('A stale authorization for the Lab 1 IP {0} exists. No automatic change. Remove it manually with Remove-DhcpServerInDC -IPAddress {0} and rerun 04.' -f $server.BaselineIPAddress)
            exit 1
        }

        Write-LabLog -Level STEP -Message ('Authorizing DHCP server {0} ({1}) in Active Directory.' -f $serverFqdn, $server.IPAddress)
        Add-DhcpServerInDC -DnsName $serverFqdn -IPAddress $server.IPAddress -ErrorAction Stop | Out-Null
        $newlyAuthorized = $true

        $null = Wait-LabCondition -Condition {
            $currentEntries = @(Get-DhcpServerInDC -ErrorAction SilentlyContinue)
            return (@($currentEntries | Where-Object { ([string]$_.IPAddress) -eq $server.IPAddress -and ([string]$_.DnsName).TrimEnd('.') -eq $serverFqdn.TrimEnd('.') }).Count -gt 0)
        } -TimeoutSeconds 60 -IntervalSeconds 3 -Description 'DHCP authorization replication'

        $entries = @(Get-DhcpServerInDC -ErrorAction Stop)
        $authorizedOk = @($entries | Where-Object { ([string]$_.IPAddress) -eq $server.IPAddress -and ([string]$_.DnsName).TrimEnd('.') -eq $serverFqdn.TrimEnd('.') }).Count -gt 0
    }

    $authorizationStatus = if (-not $authorizedOk) { 'FAIL' } elseif ($authorizationNameMismatch) { 'WARN' } else { 'PASS' }
    Add-LabCheck -Name 'DHCP authorized in AD' -Status $authorizationStatus -Detail ('{0} / {1}' -f $serverFqdn, $server.IPAddress)

    if ($newlyAuthorized) {
        Write-LabLog -Level STEP -Message 'Restarting the DHCP Server service so the new AD authorization is applied immediately.'
        Restart-Service -Name DHCPServer -Force -ErrorAction Stop
        $null = Wait-LabCondition -Condition { (Get-Service -Name DHCPServer -ErrorAction SilentlyContinue).Status -eq 'Running' } -TimeoutSeconds 60 -IntervalSeconds 2 -Description 'DHCP service after authorization'
        $service = Get-Service -Name DHCPServer -ErrorAction Stop
        Add-LabCheck -Name 'DHCP service running after authorization' -Status ($(if ($service.Status -eq 'Running') { 'PASS' } else { 'FAIL' })) -Detail $service.Status.ToString()
    }

    $result = Write-LabCheckSummary
    if ($result -eq 'FAIL') {
        Write-LabLog -Level ERROR -Message 'DHCP installation/authorization failed. Review the failed checks before running 05.'
        exit 2
    }

    Write-LabLog -Level SUCCESS -Message 'DHCP server installed and authorized. Next: 05-Configure-DHCP.ps1.'
    exit 0
}
catch {
    $message = $_.Exception.Message
    try { Write-LabLog -Level ERROR -Message ('FATAL: {0}' -f $message) } catch { Write-Host ('FATAL: {0}' -f $message) -ForegroundColor Red }
    exit 2
}
