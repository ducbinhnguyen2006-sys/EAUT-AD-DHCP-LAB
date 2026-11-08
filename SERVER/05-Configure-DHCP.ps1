<#
.SYNOPSIS
    SERVER 05 - Create/validate the IPv4 DHCP scope and options on EAUT-SRV12.

.DESCRIPTION
    Target machine : EAUT-SRV12, authorized DHCP server in binhnd363.edu.vn.
    Changes made   : creates scope 192.168.63.0 (name EAUT-LAB-63, range .100-.200,
                     lease 8 days), sets options 006 (DNS 192.168.63.2) and 015
                     (binhnd363.edu.vn), ensures option 003 is absent (no gateway),
                     ensures the scope is Active and bound to the server NIC.
    Safety         : if the scope already exists with the same name/range it is reused.
                     If an existing scope has a different name/range, the script STOPS
                     without modifying or deleting it. No reservation is created.

.NOTES
    Reboot required : NO.
    Expected output : RESULT: PASS and exit code 0.
    Exit codes      : 0 success/no change, 1 precondition/conflict, 2 operation failed,
                      3 manual reboot required.
    After this step : run 06-Verify-Server.ps1.
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
    Start-LabSession -ScriptName '05-Configure-DHCP' -LogDirectory $config.Paths.LogDirectory

    $server = $config.Server
    $dhcp = $config.Dhcp
    $scopeId = Get-LabScopeId -IPAddress $dhcp.StartRange -PrefixLength $server.PrefixLength

    Write-LabLog -Level STEP -Message '=== SERVER 05 - Configure DHCP scope and options ==='

    $state = Get-LabComputerState
    Write-LabComputerState -State $state

    $pending = Get-LabPendingReboot
    if ($pending.Pending) {
        foreach ($reason in $pending.Reasons) {
            Write-LabLog -Level ERROR -Message ('Pending reboot reason: {0}' -f $reason)
        }
        Write-LabLog -Level ERROR -Message 'A reboot is pending. Reboot manually and run 05 again. No changes made.'
        exit 3
    }

    if (-not $state.PartOfDomain -or $state.DomainRole -lt 4) {
        Write-LabLog -Level ERROR -Message 'This server is not a domain controller. Complete 02 and 03 first. No changes made.'
        exit 1
    }

    Import-LabRequiredModule -Name DhcpServer -PrerequisiteMessage 'Run 04-Install-DHCP.ps1 first.'

    $service = Get-Service -Name DHCPServer -ErrorAction SilentlyContinue
    if (-not $service -or $service.Status -ne 'Running') {
        Write-LabLog -Level ERROR -Message 'DHCP Server service is not running. Run 04-Install-DHCP.ps1 first. No changes made.'
        exit 1
    }

    try {
        $entries = @(Get-DhcpServerInDC -ErrorAction Stop)
    }
    catch {
        Write-LabLog -Level ERROR -Message ('Cannot read DHCP authorization from AD: {0}. Run 04 first. No changes made.' -f $_.Exception.Message)
        exit 1
    }
    $authorized = @($entries | Where-Object { ([string]$_.IPAddress) -eq $server.IPAddress }).Count -gt 0
    if (-not $authorized) {
        Write-LabLog -Level ERROR -Message 'This DHCP server is not authorized in AD. Run 04-Install-DHCP.ps1 first. No changes made.'
        exit 1
    }

    $adapter = Get-LabNetworkAdapter -MacAddress $server.MacAddress -KnownIPs @($server.IPAddress, $server.BaselineIPAddress)
    $addresses = @(Get-LabInterfaceAddresses -InterfaceIndex $adapter.ifIndex)
    $ipOk = @($addresses | Where-Object { $_.IPAddress -eq $server.IPAddress -and $_.PrefixLength -eq $server.PrefixLength }).Count -eq 1
    if (-not $ipOk) {
        Write-LabLog -Level ERROR -Message ('IPv4 {0}/{1} is not configured on the target adapter. Run 01 and reboot first. No changes made.' -f $server.IPAddress, $server.PrefixLength)
        exit 1
    }
    Write-LabLog -Level INFO -Message ('Target adapter: {0} | ifIndex {1}' -f $adapter.Name, $adapter.ifIndex)

    if (-not $dhcp.Router) {
        $serverRouterOption = @()
        try {
            $serverRouterOption = @(Get-DhcpServerv4OptionValue -OptionId 3 -ErrorAction SilentlyContinue | Where-Object { $_.OptionId -eq 3 })
        }
        catch {
            $serverRouterOption = @()
        }
        if ($serverRouterOption.Count -gt 0) {
            $serverRouterValues = @($serverRouterOption[0].Value | ForEach-Object { [string]$_ }) -join ', '
            Write-LabLog -Level ERROR -Message ('Server-level DHCP option 003 exists with value(s): {0}. This lab must not provide a default gateway.' -f $serverRouterValues)
            Write-LabLog -Level ERROR -Message 'Clients may receive an unwanted default route even if the scope option is absent. The script does NOT delete server-level option 003 automatically. Remove it manually only after confirming its impact, then rerun 05.'
            Add-LabCheck -Name 'Server-level option 003 absent' -Status 'FAIL' -Detail ('Server-level option 003: {0}' -f $serverRouterValues)
            [void](Write-LabCheckSummary)
            exit 1
        }
    }

    $allScopes = @(Get-DhcpServerv4Scope -ErrorAction Stop)
    $existingScope = @($allScopes | Where-Object { [string]$_.ScopeId -eq $scopeId }) | Select-Object -First 1

    $scopeStartNumber = ConvertTo-LabUInt32 -IPAddress $dhcp.StartRange
    $scopeEndNumber = ConvertTo-LabUInt32 -IPAddress $dhcp.EndRange

    $conflicts = @()
    foreach ($otherScope in $allScopes) {
        if ([string]$otherScope.ScopeId -eq $scopeId) { continue }
        $otherStart = ConvertTo-LabUInt32 -IPAddress ([string]$otherScope.StartRange)
        $otherEnd = ConvertTo-LabUInt32 -IPAddress ([string]$otherScope.EndRange)
        if ($otherStart -le $scopeEndNumber -and $otherEnd -ge $scopeStartNumber) {
            $conflicts += $otherScope
        }
    }

    if ($existingScope) {
        Write-LabLog -Level INFO -Message ('Scope {0} already exists. Validating its configuration.' -f $scopeId)
        if ($conflicts.Count -gt 0) {
            $conflictText = ($conflicts | ForEach-Object { '{0} {1}-{2}' -f $_.ScopeId, $_.StartRange, $_.EndRange }) -join '; '
            Write-LabLog -Level ERROR -Message ('The target scope overlaps other scope(s): {0}. No changes were made. Resolve manually or restore Snapshot Lab 1.' -f $conflictText)
            exit 1
        }

        $mismatches = New-Object System.Collections.Generic.List[string]
        if ([string]$existingScope.Name -ne $dhcp.ScopeName) {
            $mismatches.Add(("Name: current '{0}' vs expected '{1}'" -f $existingScope.Name, $dhcp.ScopeName))
        }
        if ([string]$existingScope.StartRange -ne $dhcp.StartRange) {
            $mismatches.Add(("StartRange: current '{0}' vs expected '{1}'" -f $existingScope.StartRange, $dhcp.StartRange))
        }
        if ([string]$existingScope.EndRange -ne $dhcp.EndRange) {
            $mismatches.Add(("EndRange: current '{0}' vs expected '{1}'" -f $existingScope.EndRange, $dhcp.EndRange))
        }
        if ([string]$existingScope.SubnetMask -ne $server.SubnetMask) {
            $mismatches.Add(("SubnetMask: current '{0}' vs expected '{1}'" -f $existingScope.SubnetMask, $server.SubnetMask))
        }

        if ($mismatches.Count -gt 0) {
            foreach ($mismatch in $mismatches) {
                Write-LabLog -Level ERROR -Message ('Scope mismatch - {0}' -f $mismatch)
            }
            Write-LabLog -Level ERROR -Message 'The script does NOT modify or delete an existing mismatched scope. Resolve manually or restore Snapshot Lab 1. No changes made.'
            exit 1
        }

        Write-LabLog -Level INFO -Message ('Existing scope state before update: State={0}, LeaseDays={1}.' -f $existingScope.State, $existingScope.LeaseDuration.TotalDays)
        Write-LabLog -Level INFO -Message 'Existing scope matches the configuration. Ensuring Active state and lease duration.'
        Set-DhcpServerv4Scope -ScopeId $scopeId -State Active -LeaseDuration (New-TimeSpan -Days $dhcp.LeaseDays) -ErrorAction Stop
    }
    else {
        if ($conflicts.Count -gt 0) {
            $conflictText = ($conflicts | ForEach-Object { '{0} {1}-{2}' -f $_.ScopeId, $_.StartRange, $_.EndRange }) -join '; '
            Write-LabLog -Level ERROR -Message ('Overlapping DHCP scope(s) exist: {0}. No scope was created. Resolve manually or restore Snapshot Lab 1.' -f $conflictText)
            exit 1
        }

        Write-LabLog -Level STEP -Message ('Creating scope {0} ({1}-{2}, lease {3} days).' -f $dhcp.ScopeName, $dhcp.StartRange, $dhcp.EndRange, $dhcp.LeaseDays)
        Add-DhcpServerv4Scope -Name $dhcp.ScopeName -StartRange $dhcp.StartRange -EndRange $dhcp.EndRange -SubnetMask $server.SubnetMask -LeaseDuration (New-TimeSpan -Days $dhcp.LeaseDays) -State Active -ErrorAction Stop
    }

    Write-LabLog -Level STEP -Message 'Configuring scope options 006 and 015 (and 003 only if a gateway is configured).'
    $oldOptions = @(Get-DhcpServerv4OptionValue -ScopeId $scopeId -ErrorAction SilentlyContinue)
    foreach ($oldOption in $oldOptions) {
        $oldValues = @($oldOption.Value | ForEach-Object { [string]$_ }) -join ', '
        Write-LabLog -Level INFO -Message ('Existing scope option before update: OptionId={0}, Value={1}' -f $oldOption.OptionId, $oldValues)
    }
    $optionParams = @{
        ScopeId     = $scopeId
        DnsServer   = $dhcp.DnsServers
        DnsDomain   = $dhcp.DnsDomain
        ErrorAction = 'Stop'
    }
    if ($dhcp.Router) {
        $optionParams.Router = $dhcp.Router
    }
    Set-DhcpServerv4OptionValue @optionParams

    if (-not $dhcp.Router) {
        $routerOption = $null
        try {
            $routerOption = Get-DhcpServerv4OptionValue -ScopeId $scopeId -OptionId 3 -ErrorAction Stop
        }
        catch {
            $routerOption = $null
        }
        if ($routerOption) {
            Write-LabLog -Level WARN -Message 'Removing scope option 003 (Router) because the lab has no default gateway.'
            try {
                Remove-DhcpServerv4OptionValue -ScopeId $scopeId -OptionId 3 -Confirm:$false -ErrorAction Stop
            }
            catch {
                Write-LabLog -Level WARN -Message ('Could not remove option 003: {0}. The final verification below will report it.' -f $_.Exception.Message)
            }
        }
    }

    Write-LabLog -Level STEP -Message 'Ensuring the DHCP service is bound to the server IPv4 interface.'
    $binding = @(Get-DhcpServerv4Binding -ErrorAction Stop | Where-Object { ([string]$_.IPAddress) -eq $server.IPAddress })
    if ($binding.Count -eq 0 -or -not $binding[0].BindingState) {
        Set-DhcpServerv4Binding -InterfaceAlias $adapter.Name -BindingState $true -ErrorAction Stop
        Write-LabLog -Level INFO -Message ('DHCP service bound to {0}.' -f $adapter.Name)
    }
    else {
        Write-LabLog -Level INFO -Message 'DHCP service is already bound to the server IPv4 interface.'
    }

    $scope = Get-DhcpServerv4Scope -ScopeId $scopeId -ErrorAction Stop
    $scopeNameOk = ([string]$scope.Name -eq $dhcp.ScopeName)
    $scopeRangeOk = (([string]$scope.StartRange -eq $dhcp.StartRange) -and ([string]$scope.EndRange -eq $dhcp.EndRange))
    $scopeMaskOk = ([string]$scope.SubnetMask -eq $server.SubnetMask)
    $scopeStateOk = ($scope.State -eq 'Active')
    $leaseOk = ([math]::Abs($scope.LeaseDuration.TotalDays - $dhcp.LeaseDays) -lt 0.01)
    Add-LabCheck -Name 'DHCP scope configuration' -Status ($(if ($scopeNameOk -and $scopeRangeOk -and $scopeMaskOk -and $scopeStateOk -and $leaseOk) { 'PASS' } else { 'FAIL' })) -Detail ('Name={0}, Range={1}-{2}, Mask={3}, State={4}, LeaseDays={5}' -f $scope.Name, $scope.StartRange, $scope.EndRange, $scope.SubnetMask, $scope.State, $scope.LeaseDuration.TotalDays)

    $options = @(Get-DhcpServerv4OptionValue -ScopeId $scopeId -ErrorAction Stop)
    $dnsOption = @($options | Where-Object { $_.OptionId -eq 6 }) | Select-Object -First 1
    $domainOption = @($options | Where-Object { $_.OptionId -eq 15 }) | Select-Object -First 1
    $routerOption = @($options | Where-Object { $_.OptionId -eq 3 })

    $actualDns = @()
    if ($dnsOption) { $actualDns = @($dnsOption.Value | ForEach-Object { [string]$_ }) }
    $dnsOptionOk = ((($actualDns | Sort-Object) -join ',') -eq ((@($dhcp.DnsServers) | Sort-Object) -join ','))
    Add-LabCheck -Name 'DHCP option 006 DNS' -Status ($(if ($dnsOptionOk) { 'PASS' } else { 'FAIL' })) -Detail ($actualDns -join ', ')

    $actualDomain = ''
    if ($domainOption) { $actualDomain = [string]$domainOption.Value }
    $domainOptionOk = ($actualDomain -eq $dhcp.DnsDomain)
    Add-LabCheck -Name 'DHCP option 015 DNS domain' -Status ($(if ($domainOptionOk) { 'PASS' } else { 'FAIL' })) -Detail $actualDomain

    if ($dhcp.Router) {
        $actualRouter = @()
        if ($routerOption.Count -gt 0) { $actualRouter = @($routerOption[0].Value | ForEach-Object { [string]$_ }) }
        $routerOk = @($actualRouter | Where-Object { $_ -eq $dhcp.Router }).Count -gt 0
        Add-LabCheck -Name 'DHCP option 003 Router' -Status ($(if ($routerOk) { 'PASS' } else { 'FAIL' })) -Detail ($actualRouter -join ', ')
    }
    else {
        Add-LabCheck -Name 'DHCP option 003 absent (no gateway)' -Status ($(if ($routerOption.Count -eq 0) { 'PASS' } else { 'FAIL' })) -Detail ('Option 003 entries: {0}' -f $routerOption.Count)
    }

    $binding = @(Get-DhcpServerv4Binding -ErrorAction Stop | Where-Object { ([string]$_.IPAddress) -eq $server.IPAddress -and $_.BindingState -eq $true })
    Add-LabCheck -Name 'DHCP bound to server IPv4' -Status ($(if ($binding.Count -gt 0) { 'PASS' } else { 'FAIL' })) -Detail $server.IPAddress

    $result = Write-LabCheckSummary
    if ($result -eq 'FAIL') {
        Write-LabLog -Level ERROR -Message 'DHCP scope verification failed. Review the failed checks before running 06.'
        exit 2
    }

    Write-LabLog -Level SUCCESS -Message 'DHCP scope configured. Next: 06-Verify-Server.ps1.'
    exit 0
}
catch {
    $message = $_.Exception.Message
    try { Write-LabLog -Level ERROR -Message ('FATAL: {0}' -f $message) } catch { Write-Host ('FATAL: {0}' -f $message) -ForegroundColor Red }
    exit 2
}
