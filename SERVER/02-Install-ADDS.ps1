<#
.SYNOPSIS
    SERVER 02 - Install AD DS/DNS and create the binhnd363.edu.vn forest.

.DESCRIPTION
    Target machine : EAUT-SRV12 (Windows Server 2019), prepared by 01-Server-Prepare.ps1.
    Changes made   : installs the AD-Domain-Services and DNS roles, creates a new forest
                     binhnd363.edu.vn (NetBIOS BINHND363) and promotes this server to the
                     first domain controller.
    Safety         : detects an existing domain controller and skips promotion.
                     Allows a safe rerun when the AD DS role is installed but NTDS is still
                     disabled, which is the normal pre-promotion state.
                     Stops if another domain or a partial promotion is detected.
                     The DSRM password is read at runtime and is never logged.

.NOTES
    Reboot required : YES. Install-ADDSForest is invoked with -NoRebootOnCompletion and
                      the script NEVER reboots. Reboot manually from VMware console.
    Expected output : exit code 3 (manual reboot required) after successful promotion.
                      Rerun after reboot -> exit code 0 (already a DC).
    Exit codes      : 0 success/no change, 1 precondition failed, 2 operation failed,
                      3 manual reboot required.
    Limitation      : forest creation/promotion is irreversible in-place. If promotion
                      fails halfway, restore Snapshot Lab 1 instead of deleting AD objects.
    After this step : reboot manually, then run 03-Verify-AD.ps1.
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

$phase = 'initialization'
$roleInstallAttempted = $false
$promotionAttempted = $false

try {
    Assert-LabAdministrator
    Assert-LabPowerShell51
    $config = Import-LabConfig -ScriptRoot $scriptRoot
    Start-LabSession -ScriptName '02-Install-ADDS' -LogDirectory $config.Paths.LogDirectory

    $server = $config.Server
    $domain = $config.Domain
    $domainFqdn = $domain.DnsName

    Write-LabLog -Level STEP -Message '=== SERVER 02 - Install AD DS/DNS and create forest ==='

    $phase = 'prechecks'
    $state = Get-LabComputerState
    Write-LabComputerState -State $state

    $pending = Get-LabPendingReboot
    if ($pending.Pending) {
        foreach ($reason in $pending.Reasons) {
            Write-LabLog -Level ERROR -Message ('Pending reboot reason: {0}' -f $reason)
        }
        Write-LabLog -Level ERROR -Message 'A reboot is pending. Reboot the VM manually and run 02 again. No changes made.'
        exit 3
    }

    if ($state.Name -ne $server.Name) {
        Write-LabLog -Level ERROR -Message ('Computer name is {0}; expected {1}. Run 01-Server-Prepare.ps1 and reboot first. No changes made.' -f $state.Name, $server.Name)
        exit 1
    }

    $adapter = Get-LabNetworkAdapter -MacAddress $server.MacAddress -KnownIPs @($server.IPAddress, $server.BaselineIPAddress)
    $addresses = @(Get-LabInterfaceAddresses -InterfaceIndex $adapter.ifIndex)
    $ipOk = @($addresses | Where-Object { $_.IPAddress -eq $server.IPAddress -and $_.PrefixLength -eq $server.PrefixLength }).Count -eq 1

    $dnsObject = Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    $dnsNow = @()
    if ($dnsObject) { $dnsNow = @($dnsObject.ServerAddresses) }
    $dnsOk = ((($dnsNow | Sort-Object) -join ',') -eq ((@($server.DnsServers) | Sort-Object) -join ','))

    if ($state.DomainRole -ge 4) {
        Import-LabRequiredModule -Name ActiveDirectory -PrerequisiteMessage 'A domain controller should expose the ActiveDirectory module.'
        try {
            $adDomain = Get-ADDomain -ErrorAction Stop
        }
        catch {
            Write-LabLog -Level ERROR -Message ('This computer reports a domain controller role but AD DS is not reachable: {0}. Reboot if promotion was just completed; otherwise restore Snapshot Lab 1. No changes made.' -f $_.Exception.Message)
            exit 1
        }

        if ($adDomain.DNSRoot -eq $domainFqdn) {
            try {
                Set-LabDnsClientServers -InterfaceIndex $adapter.ifIndex -DnsServers $server.DnsServers | Out-Null
                Add-LabCheck -Name 'DNS client after promotion' -Status 'PASS' -Detail ('DNS client set to {0}' -f ($server.DnsServers -join ', '))
            }
            catch {
                Write-LabLog -Level WARN -Message ('DNS client could not be reset to configured server: {0}' -f $_.Exception.Message)
            }

            Write-LabLog -Level SUCCESS -Message ('Server is already a domain controller for {0}. Promotion is skipped.' -f $domainFqdn)
            Add-LabCheck -Name 'AD DS domain controller' -Status 'PASS' -Detail ('Domain: {0}' -f $adDomain.DNSRoot)
            [void](Write-LabCheckSummary)
            exit 0
        }

        Write-LabLog -Level ERROR -Message ('Server is a domain controller for {0}, but expected {1}. No changes made; manual decision required.' -f $adDomain.DNSRoot, $domainFqdn)
        exit 1
    }

    if (-not $ipOk -or -not $dnsOk) {
        Write-LabLog -Level ERROR -Message ('Preconditions failed: IPv4 target={0}, DNS target={1}. Run 01-Server-Prepare.ps1 and reboot first. No changes made.' -f $ipOk, $dnsOk)
        exit 1
    }

    if ($state.PartOfDomain) {
        Write-LabLog -Level ERROR -Message ('Server is a member of domain {0}. Expected a standalone server before forest creation. No changes made.' -f $state.Domain)
        exit 1
    }

    $addsFeature = Get-WindowsFeature -Name AD-Domain-Services
    $dnsFeature = Get-WindowsFeature -Name DNS
    $addsInstalled = ($addsFeature.InstallState.ToString() -eq 'Installed')
    $dnsInstalled = ($dnsFeature.InstallState.ToString() -eq 'Installed')

    $adDsState = Get-LabAdDsInstallState
    $promotionEvidence = New-Object System.Collections.Generic.List[string]

    if ($adDsState.NtdsServicePresent) {
        if ($adDsState.NtdsStartType -ne 'Disabled') {
            $promotionEvidence.Add(('NTDS service is present with StartType={0}, Status={1}' -f $adDsState.NtdsStartType, $adDsState.NtdsStatus))
        }
        if ($adDsState.NtdsDatabasePresent) {
            $promotionEvidence.Add(('NTDS database is present at {0}' -f $adDsState.NtdsDatabasePath))
        }
    }
    elseif ($adDsState.NtdsDatabasePresent) {
        $promotionEvidence.Add(('NTDS database exists without the NTDS service at {0}' -f $adDsState.NtdsDatabasePath))
    }

    if ($adDsState.ProductType -eq 'LanmanNT') {
        $promotionEvidence.Add('ProductType is LanmanNT (domain controller role)')
    }

    if ($promotionEvidence.Count -gt 0) {
        Write-LabLog -Level ERROR -Message 'AD DS promotion state is not clean: the server is not a domain controller, but promotion evidence exists.'
        foreach ($item in $promotionEvidence) {
            Write-LabLog -Level ERROR -Message ('Promotion evidence: {0}' -f $item)
        }
        Write-LabLog -Level ERROR -Message 'Do NOT rerun promotion blindly. If promotion was just completed, reboot manually and run 03-Verify-AD.ps1. If the server is still not a domain controller, restore Snapshot Lab 1. No changes made.'
        exit 1
    }

    if ($addsInstalled -and $adDsState.NtdsServicePresent -and $adDsState.NtdsStartType -eq 'Disabled') {
        Write-LabLog -Level INFO -Message 'AD DS role is installed and the NTDS service is disabled/stopped. This is the expected pre-promotion state; a previous run did not promote this server.'
    }

    Write-LabLog -Level INFO -Message ('Role state before changes: AD-Domain-Services={0}, DNS={1}.' -f $addsFeature.InstallState, $dnsFeature.InstallState)

    $phase = 'credentials'
    Write-LabLog -Level WARN -Message 'DSRM password requirement: at least 7 characters and 3 of these 4 categories: uppercase, lowercase, digit, symbol. The password is NOT logged.'
    $dsrmPassword = Read-LabSecurePassword -Prompt ('DSRM password for {0}' -f $server.Name) -MinimumLength 7 -RequireComplexity

    $phase = 'confirmation'
    try {
        Confirm-LabAction -Message ('About to create a NEW forest {0} (NetBIOS {1}) on {2}. This cannot be undone inside the VM. Rollback = restore Snapshot Lab 1.' -f $domainFqdn, $domain.NetbiosName, $server.Name) -ExpectedWord 'CREATE'
    }
    catch {
        Write-LabLog -Level WARN -Message ('Forest creation was not confirmed: {0}' -f $_.Exception.Message)
        Write-LabLog -Level WARN -Message 'The confirmation step runs before role installation. No AD DS/DNS roles were installed and no forest promotion was started by this run.'
        exit 1
    }

    $phase = 'role-install'
    $addsResult = $null
    $dnsResult = $null
    if (-not $addsInstalled) {
        Write-LabLog -Level STEP -Message 'Installing the AD-Domain-Services role.'
        $roleInstallAttempted = $true
        $addsResult = Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools -ErrorAction Stop
        Write-LabLog -Level INFO -Message ('AD-Domain-Services: Success={0}, RestartNeeded={1}' -f $addsResult.Success, $addsResult.RestartNeeded)
        if (-not $addsResult.Success) {
            Write-LabLog -Level ERROR -Message 'AD-Domain-Services role installation reported failure. No promotion was attempted.'
            exit 2
        }
    }
    else {
        Write-LabLog -Level INFO -Message 'AD-Domain-Services role is already installed; role installation is skipped.'
    }

    if (-not $dnsInstalled) {
        Write-LabLog -Level STEP -Message 'Installing the DNS role.'
        $roleInstallAttempted = $true
        $dnsResult = Install-WindowsFeature -Name DNS -IncludeManagementTools -ErrorAction Stop
        Write-LabLog -Level INFO -Message ('DNS: Success={0}, RestartNeeded={1}' -f $dnsResult.Success, $dnsResult.RestartNeeded)
        if (-not $dnsResult.Success) {
            Write-LabLog -Level ERROR -Message 'DNS role installation reported failure. No promotion was attempted.'
            exit 2
        }
    }
    else {
        Write-LabLog -Level INFO -Message 'DNS role is already installed; role installation is skipped.'
    }

    if (($addsResult -and $addsResult.RestartNeeded -eq 'Yes') -or ($dnsResult -and $dnsResult.RestartNeeded -eq 'Yes')) {
        Write-LabLog -Level WARN -Message 'Role installation requires a reboot before promotion. Reboot manually, then run 02 again. No promotion was attempted.'
        exit 3
    }

    $addsFeature = Get-WindowsFeature -Name AD-Domain-Services
    $dnsFeature = Get-WindowsFeature -Name DNS
    Add-LabCheck -Name 'AD-Domain-Services role' -Status ($(if ($addsFeature.InstallState.ToString() -eq 'Installed') { 'PASS' } else { 'FAIL' })) -Detail $addsFeature.InstallState.ToString()
    Add-LabCheck -Name 'DNS role' -Status ($(if ($dnsFeature.InstallState.ToString() -eq 'Installed') { 'PASS' } else { 'FAIL' })) -Detail $dnsFeature.InstallState.ToString()

    if ($addsFeature.InstallState.ToString() -ne 'Installed' -or $dnsFeature.InstallState.ToString() -ne 'Installed') {
        Write-LabLog -Level ERROR -Message 'Role installation did not reach the Installed state. No promotion was attempted.'
        exit 2
    }

    $phase = 'module-import'
    Import-LabRequiredModule -Name ADDSDeployment -PrerequisiteMessage 'AD DS deployment module is missing; role installation may have failed.'

    $phase = 'promotion'
    $promoteParams = @{
        DomainName                    = $domainFqdn
        DomainNetbiosName             = $domain.NetbiosName
        InstallDns                    = [bool]$domain.InstallDns
        ForestMode                    = $domain.ForestMode
        DomainMode                    = $domain.DomainMode
        CreateDnsDelegation           = [bool]$domain.CreateDnsDelegation
        SafeModeAdministratorPassword = $dsrmPassword
        NoRebootOnCompletion          = $true
        Force                         = $true
        Confirm                       = $false
    }

    Write-LabLog -Level STEP -Message 'Running Install-ADDSForest. Automatic reboot is disabled by design.'
    $promotionAttempted = $true
    $promotionOutput = Install-ADDSForest @promoteParams -ErrorAction Stop 2>&1
    foreach ($line in @($promotionOutput)) {
        if ($null -ne $line -and $line.ToString().Trim().Length -gt 0) {
            Write-LabLog -Level INFO -Message ('[ADDS] {0}' -f $line.ToString())
        }
    }

    $phase = 'post-promotion-dns'
    try {
        Set-LabDnsClientServers -InterfaceIndex $adapter.ifIndex -DnsServers $server.DnsServers | Out-Null
        Add-LabCheck -Name 'DNS client after promotion' -Status 'PASS' -Detail ('DNS client set to {0}' -f ($server.DnsServers -join ', '))
    }
    catch {
        Write-LabLog -Level WARN -Message ('DNS client could not be reset to the configured server after promotion: {0}. START-SERVER will retry after the reboot.' -f $_.Exception.Message)
        Add-LabCheck -Name 'DNS client after promotion' -Status 'WARN' -Detail $_.Exception.Message
    }

    $phase = 'promotion-validation'
    Add-LabCheck -Name 'Forest promotion command' -Status 'PASS' -Detail ('Forest {0}' -f $domainFqdn)

    $adDsStateAfter = Get-LabAdDsInstallState
    $promotionStaged = ($adDsStateAfter.NtdsServicePresent -and ($adDsStateAfter.NtdsDatabasePresent -or $adDsStateAfter.ProductType -eq 'LanmanNT'))
    $promotionDetail = 'NTDS={0}; StartType={1}; Database={2}; ProductType={3}' -f $adDsStateAfter.NtdsServicePresent, $adDsStateAfter.NtdsStartType, $adDsStateAfter.NtdsDatabasePresent, $adDsStateAfter.ProductType
    Add-LabCheck -Name 'NTDS promotion state' -Status ($(if ($promotionStaged) { 'PASS' } else { 'FAIL' })) -Detail $promotionDetail

    $pendingAfter = Get-LabPendingReboot
    Add-LabCheck -Name 'Manual reboot required' -Status 'WARN' -Detail ($(if ($pendingAfter.Pending) { $pendingAfter.Reasons -join '; ' } else { 'promotion completed; reboot before verification' }))

    [void](Write-LabCheckSummary)

    if (-not $promotionStaged) {
        Write-LabLog -Level ERROR -Message 'Install-ADDSForest returned, but the expected NTDS promotion state was not found. Reboot manually and run 03-Verify-AD.ps1; do not retry blindly. Restore Snapshot Lab 1 if the server is still not a domain controller.'
        exit 2
    }

    Write-LabLog -Level WARN -Message 'MANUAL STEP REQUIRED: reboot this VM from the VMware console now.'
    Write-LabLog -Level WARN -Message 'Do NOT run 03-Verify-AD.ps1 before the reboot. After reboot, run 03-Verify-AD.ps1.'
    exit 3
}
catch {
    $message = $_.Exception.Message
    try { Write-LabLog -Level ERROR -Message ('FATAL: {0}' -f $message) } catch { Write-Host ('FATAL: {0}' -f $message) -ForegroundColor Red }
    try { Write-LabLog -Level ERROR -Message ('Failure phase: {0}' -f $phase) } catch { }
    if ($promotionAttempted) {
        Write-LabLog -Level ERROR -Message 'Install-ADDSForest was started. Promotion may be partially applied; do not rerun 02 blindly. Reboot manually and run 03-Verify-AD.ps1 to reassess. If the server is still not a domain controller, restore Snapshot Lab 1.'
    }
    elseif ($roleInstallAttempted) {
        Write-LabLog -Level ERROR -Message 'No forest promotion was started by this run, but AD DS/DNS role installation may have changed this server. Rerun 02; it will detect the installed roles and continue safely.'
    }
    else {
        Write-LabLog -Level ERROR -Message 'No AD DS/DNS role installation and no forest promotion was started by this run.'
    }
    Write-LabLog -Level ERROR -Message 'No automatic cleanup was performed.'
    exit 2
}
