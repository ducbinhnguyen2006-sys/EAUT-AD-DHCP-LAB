<#
.SYNOPSIS
    CLIENT 02 - Join WRK01 to binhnd363.edu.vn.

.DESCRIPTION
    Target machine : WRK01 (Windows 10 Pro), prepared by 01-Client-Prepare.ps1 and rebooted.
    Changes made   : joins the computer to binhnd363.edu.vn using domain credentials
                     entered at runtime.
    Safety         : if already joined to the target domain with a working secure channel,
                     the join is skipped. If joined to another domain, the script stops.
                     It never unjoins the computer and never deletes AD computer objects.

.NOTES
    Reboot required : YES after a successful join. The script never reboots.
    Expected output : exit code 3 (manual reboot required) after a new join.
                      exit code 0 if already joined with a valid secure channel.
    Exit codes      : 0 success/no change, 1 precondition failed, 2 operation failed,
                      3 manual reboot required.
    Credentials     : enter BINHND363\Administrator (or another Domain Admin) when prompted.
                      The password is not logged.
    After this step : reboot manually, then run 03-Configure-DHCP.ps1.
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
    Start-LabSession -ScriptName '02-Join-Domain' -LogDirectory $config.Paths.LogDirectory

    $server = $config.Server
    $client = $config.Client
    $domain = $config.Domain
    $serverFqdn = '{0}.{1}' -f $server.Name, $domain.DnsName

    Write-LabLog -Level STEP -Message '=== CLIENT 02 - Join domain ==='

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

    if ($state.PartOfDomain) {
        if ($state.Domain -ne $domain.DnsName) {
            Write-LabLog -Level ERROR -Message ('Client is joined to unexpected domain {0}. The script never unjoins automatically. No changes made.' -f $state.Domain)
            exit 1
        }

        $secure = $false
        try { $secure = Test-ComputerSecureChannel -ErrorAction Stop } catch { $secure = $false }

        if ($secure) {
            if ($state.Name -ne $client.Name) {
                Write-LabLog -Level ERROR -Message ('Client is already joined to {0}, but the computer name is {1}; expected {2}. No changes made.' -f $domain.DnsName, $state.Name, $client.Name)
                exit 1
            }
            Write-LabLog -Level SUCCESS -Message ('Client is already joined to {0} and the secure channel is valid. Join skipped.' -f $domain.DnsName)
            Add-LabCheck -Name 'Domain membership' -Status 'PASS' -Detail ('Domain={0}, secure channel=True' -f $domain.DnsName)
            [void](Write-LabCheckSummary)
            exit 0
        }

        Write-LabLog -Level ERROR -Message ('Client is joined to {0} but the secure channel is broken. No automatic repair was attempted.' -f $domain.DnsName)
        Write-LabLog -Level WARN -Message 'Manual options: on the client run Test-ComputerSecureChannel -Repair -Credential (Get-Credential BINHND363\Administrator) and reboot; or on the DC inspect/remove a stale WRK01 computer object, then rerun 02.'
        exit 1
    }

    if ($state.Name -ne $client.Name) {
        Write-LabLog -Level ERROR -Message ('Computer name is {0}; expected {1}. Run 01-Client-Prepare.ps1 and reboot first. No changes made.' -f $state.Name, $client.Name)
        exit 1
    }

    $editionCheck = Test-LabWindowsEdition
    Add-LabCheck -Name 'Windows edition supports domain join' -Status $editionCheck.Status -Detail $editionCheck.Detail
    if (-not $editionCheck.Supported) {
        Write-LabLog -Level ERROR -Message $editionCheck.Message
        [void](Write-LabCheckSummary)
        exit 1
    }

    $adapter = Get-LabNetworkAdapter -MacAddress $client.MacAddress -KnownIPs @($client.StaticIPAddress, $client.BaselineIPAddress)
    $addresses = @(Get-LabInterfaceAddresses -InterfaceIndex $adapter.ifIndex)
    $ipOk = @($addresses | Where-Object { $_.IPAddress -eq $client.StaticIPAddress -and $_.PrefixLength -eq $client.PrefixLength }).Count -eq 1
    $dnsObject = Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    $dnsNow = @()
    if ($dnsObject) { $dnsNow = @($dnsObject.ServerAddresses) }
    $dnsOk = ((($dnsNow | Sort-Object) -join ',') -eq $server.IPAddress)

    if (-not $ipOk -or -not $dnsOk) {
        Write-LabLog -Level ERROR -Message ('Preconditions failed: IPv4 {0}/{1} present={2}, DNS points to {3}={4}. Run 01 and reboot first. No changes made.' -f $client.StaticIPAddress, $client.PrefixLength, $ipOk, $server.IPAddress, $dnsOk)
        exit 1
    }

    Write-LabLog -Level STEP -Message 'Running domain/DNS/port prechecks against the domain controller.'
    $srvName = '_ldap._tcp.dc._msdcs.{0}' -f $domain.DnsName
    $srvOk = $false
    try {
        $answers = @(Resolve-DnsName -Name $srvName -Type SRV -Server $server.IPAddress -DnsOnly -ErrorAction Stop)
        $targets = @($answers | Where-Object { $_.NameTarget } | ForEach-Object { $_.NameTarget.TrimEnd('.').ToLowerInvariant() })
        $srvOk = @($targets | Where-Object { $_ -eq $serverFqdn.ToLowerInvariant() }).Count -gt 0
        Add-LabCheck -Name 'AD LDAP SRV record' -Status ($(if ($srvOk) { 'PASS' } else { 'FAIL' })) -Detail ($targets -join ', ')
    }
    catch {
        Add-LabCheck -Name 'AD LDAP SRV record' -Status 'FAIL' -Detail $_.Exception.Message
    }

    $portResults = @{}
    foreach ($port in @(53, 88, 389, 445, 135)) {
        $portResults[$port] = Test-LabTcpPort -ComputerName $server.IPAddress -Port $port
    }
    $portsOk = @($portResults.Values | Where-Object { $_ -eq $false }).Count -eq 0
    Add-LabCheck -Name 'DC TCP ports (53,88,389,445,135)' -Status ($(if ($portsOk) { 'PASS' } else { 'FAIL' })) -Detail (($portResults.Keys | Sort-Object | ForEach-Object { '{0}={1}' -f $_, $portResults[$_] }) -join ', ')

    $pingOk = Test-Connection -ComputerName $server.IPAddress -Count 2 -Quiet -ErrorAction SilentlyContinue
    Add-LabCheck -Name 'Ping domain controller' -Status ($(if ($pingOk) { 'PASS' } else { 'WARN' })) -Detail ($(if ($pingOk) { $server.IPAddress } else { 'ICMP blocked or not answered; DNS/TCP checks remain authoritative.' }))

    [void](Write-LabCheckSummary)

    if (-not $srvOk -or -not $portsOk) {
        Write-LabLog -Level ERROR -Message 'Domain join prechecks failed. Fix DNS/network/DC first; no join was attempted.'
        Write-LabLog -Level WARN -Message 'On the server, confirm 03-Verify-AD.ps1 passes, DHCP/AD traffic is allowed, and the client DNS is 192.168.63.2.'
        exit 1
    }

    $credential = Get-Credential -UserName ('{0}\Administrator' -f $domain.NetbiosName) -Message ('Enter a Domain Admin account for {0} (for example {1}\Administrator). The password is not logged.' -f $domain.DnsName, $domain.NetbiosName)
    if (-not $credential) {
        Write-LabLog -Level ERROR -Message 'No credential was supplied. No changes made.'
        exit 1
    }

    Confirm-LabAction -Message ('About to join {0} to domain {1} using the supplied credential. A manual reboot will be required.' -f $client.Name, $domain.DnsName) -ExpectedWord 'JOIN'

    Write-LabLog -Level STEP -Message ('Joining {0} to {1}.' -f $client.Name, $domain.DnsName)
    $joinSucceeded = $false
    try {
        $joinResult = Add-Computer -DomainName $domain.DnsName -Credential $credential -PassThru -Confirm:$false -ErrorAction Stop
        $joinSucceeded = $true
        if ($joinResult) {
            Write-LabLog -Level INFO -Message ('Add-Computer result: {0}' -f ($joinResult | Out-String).Trim())
        }
    }
    catch {
        $message = $_.Exception.Message
        Write-LabLog -Level ERROR -Message ('Domain join failed: {0}' -f $message)
        if ($message -match 'already exists|existing computer account|same name|account.*exist|already in the domain|duplicate') {
            Write-LabLog -Level WARN -Message 'Possible stale AD computer object. On the DC inspect: Get-ADComputer -Identity WRK01.'
            Write-LabLog -Level WARN -Message 'Only if you confirm it is stale, remove it manually on the DC: Remove-ADComputer -Identity WRK01 -Confirm. This script does NOT delete AD objects.'
            Write-LabLog -Level WARN -Message 'Alternatively repair the channel manually: Test-ComputerSecureChannel -Repair -Credential (Get-Credential BINHND363\Administrator), then reboot.'
        }
        throw
    }

    $newState = Get-LabComputerState
    $joined = ($newState.PartOfDomain -and $newState.Domain -eq $domain.DnsName)
    Add-LabCheck -Name 'Domain membership after join' -Status ($(if ($joined) { 'PASS' } else { 'WARN' })) -Detail ($(if ($joined) { 'Domain={0}, PartOfDomain={1}' -f $newState.Domain, $newState.PartOfDomain } else { 'Not visible yet; the join command succeeded and will be active after the reboot.' }))

    $secure = $false
    try { $secure = Test-ComputerSecureChannel -ErrorAction Stop } catch { $secure = $false }
    Add-LabCheck -Name 'Machine secure channel' -Status ($(if ($secure) { 'PASS' } else { 'WARN' })) -Detail ($(if ($secure) { 'Valid' } else { 'Not verified before reboot; recheck after reboot in 04' }))

    [void](Write-LabCheckSummary)

    if (-not $joinSucceeded) {
        Write-LabLog -Level ERROR -Message 'The join command did not report success. No reboot instruction was issued.'
        exit 2
    }

    Write-LabLog -Level WARN -Message 'MANUAL STEP REQUIRED: reboot this VM from the VMware console now.'
    Write-LabLog -Level WARN -Message 'After reboot you can log on with a domain account. Then run 03-Configure-DHCP.ps1.'
    exit 3
}
catch {
    $message = $_.Exception.Message
    try { Write-LabLog -Level ERROR -Message ('FATAL: {0}' -f $message) } catch { Write-Host ('FATAL: {0}' -f $message) -ForegroundColor Red }
    exit 2
}
