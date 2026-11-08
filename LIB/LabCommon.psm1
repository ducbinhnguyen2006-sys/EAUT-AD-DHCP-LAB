#requires -Version 5.1

$script:LabLogFile = $null
$script:LabChecks = New-Object System.Collections.ArrayList

function Write-LabLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ValidateSet('INFO', 'STEP', 'SUCCESS', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = '[{0}] [{1}] {2}' -f $timestamp, $Level, $Message

    switch ($Level) {
        'STEP'    { Write-Host $line -ForegroundColor Cyan }
        'SUCCESS' { Write-Host $line -ForegroundColor Green }
        'WARN'    { Write-Host $line -ForegroundColor Yellow }
        'ERROR'   { Write-Host $line -ForegroundColor Red }
        default   { Write-Host $line }
    }

    if ($script:LabLogFile) {
        try {
            Add-Content -LiteralPath $script:LabLogFile -Value $line -Encoding UTF8 -ErrorAction Stop
        }
        catch {
        }
    }
}

function Clear-LabChecks {
    [CmdletBinding()]
    param()

    $script:LabChecks = New-Object System.Collections.ArrayList
}

function Start-LabSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptName,
        [Parameter(Mandatory = $true)]
        [string]$LogDirectory
    )

    Clear-LabChecks

    if (-not (Test-Path -LiteralPath $LogDirectory)) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    }

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $script:LabLogFile = Join-Path -Path $LogDirectory -ChildPath ('{0}_{1}.log' -f $ScriptName, $stamp)
    Set-Content -LiteralPath $script:LabLogFile -Value '' -Encoding UTF8
    $script:LabChecks.Clear()

    $os = 'unknown'
    try { $os = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).Caption } catch { }

    Write-LabLog -Level STEP -Message ('=== {0} ===' -f $ScriptName)
    Write-LabLog -Level INFO -Message ('Log file : {0}' -f $script:LabLogFile)
    Write-LabLog -Level INFO -Message ('Computer : {0}' -f $env:COMPUTERNAME)
    Write-LabLog -Level INFO -Message ('User     : {0}' -f $env:USERNAME)
    Write-LabLog -Level INFO -Message ('PowerShell: {0}' -f $PSVersionTable.PSVersion.ToString())
    Write-LabLog -Level INFO -Message ('OS       : {0}' -f $os)
}

function Find-LabConfigPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptRoot
    )

    $parent = Split-Path -Parent $ScriptRoot
    $grandParent = ''
    if ($parent) { $grandParent = Split-Path -Parent $parent }

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($ScriptRoot) {
        $candidates.Add((Join-Path -Path $ScriptRoot -ChildPath 'CONFIG\LabConfig.psd1'))
        $candidates.Add((Join-Path -Path $ScriptRoot -ChildPath 'LabConfig.psd1'))
    }
    if ($parent) {
        $candidates.Add((Join-Path -Path $parent -ChildPath 'CONFIG\LabConfig.psd1'))
        $candidates.Add((Join-Path -Path $parent -ChildPath 'LabConfig.psd1'))
    }
    if ($grandParent) {
        $candidates.Add((Join-Path -Path $grandParent -ChildPath 'CONFIG\LabConfig.psd1'))
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw 'LabConfig.psd1 was not found. Expected <root>\CONFIG\LabConfig.psd1 next to SERVER and CLIENT. Copy the entire EAUT-AD-DHCP-LAB folder.'
}

function Test-LabIPv4 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($Value, [ref]$parsed)) {
        return $false
    }
    return ($parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork)
}

function ConvertTo-LabUInt32 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$IPAddress
    )

    $bytes = [System.Net.IPAddress]::Parse($IPAddress).GetAddressBytes()
    [array]::Reverse($bytes)
    return [System.BitConverter]::ToUInt32($bytes, 0)
}

function Get-LabNetworkBytes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$IPAddress,
        [Parameter(Mandatory = $true)]
        [int]$PrefixLength
    )

    $ipBytes = [System.Net.IPAddress]::Parse($IPAddress).GetAddressBytes()
    $network = New-Object byte[] 4
    $fullBytes = [math]::Floor($PrefixLength / 8)
    $remainingBits = $PrefixLength % 8

    for ($i = 0; $i -lt 4; $i++) {
        if ($i -lt $fullBytes) {
            $network[$i] = $ipBytes[$i]
        }
        elseif ($i -eq $fullBytes -and $remainingBits -gt 0) {
            $mask = [byte](([math]::Pow(2, $remainingBits) - 1) * [math]::Pow(2, 8 - $remainingBits))
            $network[$i] = [byte]($ipBytes[$i] -band $mask)
        }
        else {
            $network[$i] = 0
        }
    }

    return $network
}

function Test-LabSameSubnet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$IPAddressA,
        [Parameter(Mandatory = $true)]
        [string]$IPAddressB,
        [Parameter(Mandatory = $true)]
        [int]$PrefixLength
    )

    $a = Get-LabNetworkBytes -IPAddress $IPAddressA -PrefixLength $PrefixLength
    $b = Get-LabNetworkBytes -IPAddress $IPAddressB -PrefixLength $PrefixLength
    return (($a -join '.') -eq ($b -join '.'))
}

function Get-LabSubnetMaskString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$PrefixLength
    )

    $bytes = New-Object byte[] 4
    for ($i = 0; $i -lt 4; $i++) {
        $bits = [math]::Min(8, [math]::Max(0, $PrefixLength - ($i * 8)))
        $bytes[$i] = [byte](([math]::Pow(2, $bits) - 1) * [math]::Pow(2, 8 - $bits))
    }
    return ($bytes -join '.')
}

function Test-LabConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    $errors = New-Object System.Collections.Generic.List[string]

    foreach ($section in @('Server', 'Client', 'Domain', 'Dhcp', 'Paths')) {
        if (-not $Config.ContainsKey($section)) {
            $errors.Add("Missing section '$section'.")
        }
        elseif ($Config[$section] -isnot [hashtable]) {
            $errors.Add("Section '$section' must be a hashtable.")
        }
    }

    if ($errors.Count -gt 0) {
        throw ('Invalid LabConfig.psd1: ' + ($errors -join ' | '))
    }

    $server = $Config.Server
    $client = $Config.Client
    $domain = $Config.Domain
    $dhcp = $Config.Dhcp
    $paths = $Config.Paths

    foreach ($key in @('Name', 'BaselineName', 'MacAddress', 'BaselineIPAddress', 'IPAddress', 'PrefixLength', 'SubnetMask', 'Gateway', 'DnsServers')) {
        if (-not $server.ContainsKey($key)) { $errors.Add("Missing Server.$key.") }
    }
    foreach ($key in @('Name', 'BaselineName', 'MacAddress', 'BaselineIPAddress', 'StaticIPAddress', 'PrefixLength', 'SubnetMask', 'Gateway', 'DnsServers')) {
        if (-not $client.ContainsKey($key)) { $errors.Add("Missing Client.$key.") }
    }
    foreach ($key in @('DnsName', 'NetbiosName', 'ForestMode', 'DomainMode', 'InstallDns', 'CreateDnsDelegation')) {
        if (-not $domain.ContainsKey($key)) { $errors.Add("Missing Domain.$key.") }
    }
    foreach ($key in @('ScopeName', 'StartRange', 'EndRange', 'LeaseDays', 'Router', 'DnsServers', 'DnsDomain', 'Reservation')) {
        if (-not $dhcp.ContainsKey($key)) { $errors.Add("Missing Dhcp.$key.") }
    }
    if (-not $paths.ContainsKey('LogDirectory')) { $errors.Add('Missing Paths.LogDirectory.') }

    if ($errors.Count -gt 0) {
        throw ('Invalid LabConfig.psd1: ' + ($errors -join ' | '))
    }

    $hostnamePattern = '^[A-Za-z0-9]([A-Za-z0-9-]{0,13}[A-Za-z0-9])?$'
    foreach ($hostname in @($server.Name, $server.BaselineName, $client.Name, $client.BaselineName)) {
        if ($hostname -notmatch $hostnamePattern) {
            $errors.Add("Invalid hostname '$hostname' (1-15 chars, letters/digits/hyphen, no leading/trailing hyphen).")
        }
    }

    if ($domain.NetbiosName -notmatch '^[A-Za-z0-9-]{1,15}$') {
        $errors.Add("Invalid Domain.NetbiosName '$($domain.NetbiosName)'.")
    }
    if ($domain.DnsName -notmatch '^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$') {
        $errors.Add("Invalid Domain.DnsName '$($domain.DnsName)'.")
    }
    if ($domain.NetbiosName -eq $server.Name -or $domain.NetbiosName -eq $client.Name) {
        $errors.Add('Domain.NetbiosName must not equal a computer name.')
    }
    foreach ($mode in @($domain.ForestMode, $domain.DomainMode)) {
        if ($mode -notin @('Win2008R2', 'Win2012', 'Win2012R2', 'WinThreshold')) {
            $errors.Add("Invalid forest/domain mode '$mode'.")
        }
    }

    foreach ($mac in @($server.MacAddress, $client.MacAddress)) {
        if ($mac -notmatch '^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$') {
            $errors.Add("Invalid MAC address '$mac'.")
        }
    }

    $ipValues = @(
        @{ Label = 'Server.IPAddress';         Value = $server.IPAddress },
        @{ Label = 'Server.BaselineIPAddress'; Value = $server.BaselineIPAddress },
        @{ Label = 'Client.StaticIPAddress';   Value = $client.StaticIPAddress },
        @{ Label = 'Client.BaselineIPAddress'; Value = $client.BaselineIPAddress },
        @{ Label = 'Dhcp.StartRange';          Value = $dhcp.StartRange },
        @{ Label = 'Dhcp.EndRange';            Value = $dhcp.EndRange }
    )
    foreach ($item in $ipValues) {
        if (-not (Test-LabIPv4 -Value $item.Value)) {
            $errors.Add(("Invalid IPv4 in {0}: '{1}'." -f $item.Label, $item.Value))
        }
    }

    foreach ($item in @(
        @{ Label = 'Server.Gateway'; Value = $server.Gateway },
        @{ Label = 'Client.Gateway'; Value = $client.Gateway },
        @{ Label = 'Dhcp.Router';    Value = $dhcp.Router }
    )) {
        if ($null -ne $item.Value -and $item.Value -ne '') {
            if (-not (Test-LabIPv4 -Value $item.Value)) {
                $errors.Add(("Invalid IPv4 in {0}: '{1}'." -f $item.Label, $item.Value))
            }
        }
    }

    foreach ($item in @(
        @{ Label = 'Server.DnsServers'; Value = $server.DnsServers },
        @{ Label = 'Client.DnsServers'; Value = $client.DnsServers },
        @{ Label = 'Dhcp.DnsServers';   Value = $dhcp.DnsServers }
    )) {
        if ($null -eq $item.Value -or @($item.Value).Count -eq 0) {
            $errors.Add(("{0} must contain at least one DNS server." -f $item.Label))
        }
        else {
            foreach ($dns in @($item.Value)) {
                if (-not (Test-LabIPv4 -Value $dns)) {
                    $errors.Add(("Invalid DNS IPv4 in {0}: '{1}'." -f $item.Label, $dns))
                }
                elseif ($dns -ne $server.IPAddress) {
                    $errors.Add(("{0} contains {1}, but this lab requires every DNS entry to equal Server.IPAddress ({2})." -f $item.Label, $dns, $server.IPAddress))
                }
            }
        }
    }

    foreach ($prefix in @($server.PrefixLength, $client.PrefixLength)) {
        if ($prefix -lt 8 -or $prefix -gt 30) {
            $errors.Add("Invalid PrefixLength '$prefix' (expected 8-30).")
        }
    }

    if ($errors.Count -eq 0) {
        $mask = Get-LabSubnetMaskString -PrefixLength $server.PrefixLength
        if ($server.SubnetMask -ne $mask) {
            $errors.Add("Server.SubnetMask '$($server.SubnetMask)' does not match PrefixLength $($server.PrefixLength) ('$mask').")
        }
        if ($client.SubnetMask -ne $mask) {
            $errors.Add("Client.SubnetMask '$($client.SubnetMask)' does not match PrefixLength $($client.PrefixLength) ('$mask').")
        }

        foreach ($label in @('Server.IPAddress', 'Client.StaticIPAddress', 'Dhcp.StartRange', 'Dhcp.EndRange')) {
            $value = switch ($label) {
                'Server.IPAddress'       { $server.IPAddress }
                'Client.StaticIPAddress' { $client.StaticIPAddress }
                'Dhcp.StartRange'        { $dhcp.StartRange }
                'Dhcp.EndRange'          { $dhcp.EndRange }
            }
            if (-not (Test-LabSameSubnet -IPAddressA $server.IPAddress -IPAddressB $value -PrefixLength $server.PrefixLength)) {
                $errors.Add("$label '$value' is not in the server subnet.")
            }
        }

        foreach ($gw in @($server.Gateway, $client.Gateway, $dhcp.Router)) {
            if ($null -ne $gw -and $gw -ne '' -and -not (Test-LabSameSubnet -IPAddressA $server.IPAddress -IPAddressB $gw -PrefixLength $server.PrefixLength)) {
                $errors.Add("Gateway '$gw' is not in the server subnet.")
            }
        }

        $scopeStart = ConvertTo-LabUInt32 -IPAddress $dhcp.StartRange
        $scopeEnd = ConvertTo-LabUInt32 -IPAddress $dhcp.EndRange
        if ($scopeStart -gt $scopeEnd) {
            $errors.Add('Dhcp.StartRange must be lower than or equal to Dhcp.EndRange.')
        }

        foreach ($item in @(
            @{ Label = 'Server.IPAddress';       Value = $server.IPAddress },
            @{ Label = 'Client.StaticIPAddress'; Value = $client.StaticIPAddress }
        )) {
            $number = ConvertTo-LabUInt32 -IPAddress $item.Value
            if ($number -ge $scopeStart -and $number -le $scopeEnd) {
                $errors.Add(("{0} '{1}' is inside the DHCP scope range and would conflict with leases." -f $item.Label, $item.Value))
            }
        }

        foreach ($gw in @($server.Gateway, $client.Gateway, $dhcp.Router)) {
            if ($null -ne $gw -and $gw -ne '') {
                $number = ConvertTo-LabUInt32 -IPAddress $gw
                if ($number -ge $scopeStart -and $number -le $scopeEnd) {
                    $errors.Add("Gateway '$gw' is inside the DHCP scope range; add an exclusion or move the gateway.")
                }
            }
        }

        if ($null -ne $dhcp.Reservation -and $dhcp.Reservation -ne '') {
            if (-not (Test-LabIPv4 -Value $dhcp.Reservation)) {
                $errors.Add("Invalid Dhcp.Reservation '$($dhcp.Reservation)'.")
            }
            else {
                $number = ConvertTo-LabUInt32 -IPAddress $dhcp.Reservation
                if ($number -lt $scopeStart -or $number -gt $scopeEnd) {
                    $errors.Add('Dhcp.Reservation must be inside the DHCP scope range.')
                }
            }
        }

        if ($dhcp.LeaseDays -lt 1 -or $dhcp.LeaseDays -gt 365) {
            $errors.Add('Dhcp.LeaseDays must be between 1 and 365.')
        }
        if ([string]::IsNullOrWhiteSpace($dhcp.ScopeName)) {
            $errors.Add('Dhcp.ScopeName must not be empty.')
        }
        if ($dhcp.DnsDomain -ne $domain.DnsName) {
            $errors.Add('Dhcp.DnsDomain must match Domain.DnsName.')
        }
    }

    if ([string]::IsNullOrWhiteSpace($paths.LogDirectory)) {
        $errors.Add('Paths.LogDirectory must not be empty.')
    }

    if ($errors.Count -gt 0) {
        throw ('Invalid LabConfig.psd1: ' + ($errors -join ' | '))
    }
}

function Import-LabConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptRoot
    )

    $path = Find-LabConfigPath -ScriptRoot $ScriptRoot
    $config = Import-PowerShellDataFile -LiteralPath $path -ErrorAction Stop
    Test-LabConfig -Config $config

    $projectRoot = Split-Path -Parent (Split-Path -Parent $path)
    $logOverride = $env:EAUT_LAB_LOG_DIR
    if ($logOverride) {
        $config.Paths.LogDirectory = $logOverride
    }
    elseif (-not [System.IO.Path]::IsPathRooted([string]$config.Paths.LogDirectory)) {
        $role = $env:EAUT_LAB_ROLE
        if (-not $role) {
            $leaf = Split-Path -Leaf $ScriptRoot
            if ($leaf -in @('SERVER', 'CLIENT')) {
                $role = $leaf
            }
        }
        if (-not $role) { $role = 'COMMON' }
        $config.Paths.LogDirectory = Join-Path -Path (Join-Path -Path $projectRoot -ChildPath ([string]$config.Paths.LogDirectory)) -ChildPath $role
    }

    $config.Paths.LogDirectory = [System.IO.Path]::GetFullPath([string]$config.Paths.LogDirectory)
    Write-LabLog -Level INFO -Message ('Config loaded: {0}' -f $path)
    Write-LabLog -Level INFO -Message ('Log directory: {0}' -f $config.Paths.LogDirectory)
    return $config
}

function Assert-LabAdministrator {
    [CmdletBinding()]
    param()

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must run in an elevated PowerShell window (Run as Administrator).'
    }
    Write-LabLog -Level INFO -Message 'Administrator privileges confirmed.'
}

function Assert-LabPowerShell51 {
    [CmdletBinding()]
    param()

    if ($PSVersionTable.PSVersion -lt [version]'5.1') {
        throw ('Windows PowerShell 5.1 or later is required. Current version: {0}' -f $PSVersionTable.PSVersion)
    }
    if ($PSVersionTable.PSEdition -ne 'Desktop') {
        throw ('Windows PowerShell 5.1 (Desktop edition) is required. Current edition: {0}' -f $PSVersionTable.PSEdition)
    }
    Write-LabLog -Level INFO -Message ('PowerShell version check passed: {0}' -f $PSVersionTable.PSVersion)
}

function Get-LabPendingReboot {
    [CmdletBinding()]
    param()

    $reasons = New-Object System.Collections.Generic.List[string]

    try {
        $activeName = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -Name ComputerName -ErrorAction Stop).ComputerName
        $pendingName = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -Name ComputerName -ErrorAction Stop).ComputerName
        if ($activeName -ne $pendingName) {
            $reasons.Add("Computer rename pending: '$activeName' -> '$pendingName'")
        }
    }
    catch {
    }

    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        $reasons.Add('Component Based Servicing RebootPending key exists')
    }
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        $reasons.Add('Windows Update RebootRequired key exists')
    }
    try {
        $pendingRenames = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction Stop).PendingFileRenameOperations
        if ($pendingRenames -and @($pendingRenames).Count -gt 0) {
            $reasons.Add('PendingFileRenameOperations exists')
        }
    }
    catch {
    }
    return [pscustomobject]@{
        Pending = ($reasons.Count -gt 0)
        Reasons = @($reasons)
    }
}

function Get-LabAdDsInstallState {
    [CmdletBinding()]
    param()

    $ntdsService = Get-Service -Name NTDS -ErrorAction SilentlyContinue
    $ntdsStatus = ''
    $ntdsStartType = ''
    if ($ntdsService) {
        $ntdsStatus = [string]$ntdsService.Status
        $ntdsStartType = [string]$ntdsService.StartType
    }

    $productType = ''
    try {
        $productType = [string](Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ProductOptions' -Name ProductType -ErrorAction Stop).ProductType
    }
    catch {
        $productType = ''
    }

    $parametersKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters'
    $parametersPresent = Test-Path -LiteralPath $parametersKey
    $databasePath = ''
    if ($parametersPresent) {
        try {
            $databasePath = [string](Get-ItemProperty -Path $parametersKey -Name 'DSA Database File' -ErrorAction Stop).'DSA Database File'
        }
        catch {
            $databasePath = ''
        }
    }

    $databasePresent = $false
    if ($databasePath -and (Test-Path -LiteralPath $databasePath)) {
        $databasePresent = $true
    }
    elseif (Test-Path -LiteralPath 'C:\Windows\NTDS\ntds.dit') {
        $databasePresent = $true
    }

    return [pscustomobject]@{
        NtdsServicePresent    = [bool]$ntdsService
        NtdsStatus            = $ntdsStatus
        NtdsStartType         = $ntdsStartType
        ProductType           = $productType
        NtdsParametersPresent = $parametersPresent
        NtdsDatabasePath      = $databasePath
        NtdsDatabasePresent   = $databasePresent
        NtdsDirectoryPresent  = (Test-Path -LiteralPath 'C:\Windows\NTDS')
    }
}

function Test-LabWindowsEdition {
    [CmdletBinding()]
    param(
        [string]$EditionID,
        [Nullable[int]]$OperatingSystemSKU,
        [Nullable[int]]$ProductType,
        [string]$Caption
    )

    $sourceEditionId = $EditionID
    $sourceSku = $OperatingSystemSKU
    $sourceProductType = $ProductType
    $sourceCaption = $Caption

    # 1. Query Registry for EditionID if not explicitly provided
    if (-not $PSBoundParameters.ContainsKey('EditionID')) {
        try {
            $regPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
            if (Test-Path -LiteralPath $regPath) {
                $reg = Get-ItemProperty -LiteralPath $regPath -ErrorAction Stop
                if ($reg.PSObject.Properties['EditionID'] -and [string]$reg.EditionID) {
                    $sourceEditionId = [string]$reg.EditionID
                }
            }
        }
        catch {
        }
    }

    # 2. Query CIM Win32_OperatingSystem for SKU, ProductType, Caption if not provided
    $queryCim = (-not $PSBoundParameters.ContainsKey('OperatingSystemSKU') -or
                 -not $PSBoundParameters.ContainsKey('ProductType') -or
                 -not $PSBoundParameters.ContainsKey('Caption'))
    if ($queryCim) {
        try {
            $cimOs = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
            if (-not $PSBoundParameters.ContainsKey('OperatingSystemSKU') -and $cimOs.PSObject.Properties['OperatingSystemSKU']) {
                $sourceSku = [int]$cimOs.OperatingSystemSKU
            }
            if (-not $PSBoundParameters.ContainsKey('ProductType') -and $cimOs.PSObject.Properties['ProductType']) {
                $sourceProductType = [int]$cimOs.ProductType
            }
            if (-not $PSBoundParameters.ContainsKey('Caption') -and $cimOs.PSObject.Properties['Caption']) {
                $sourceCaption = [string]$cimOs.Caption
            }
        }
        catch {
        }
    }

    $cleanEditionId = if ($sourceEditionId) { $sourceEditionId.Trim() } else { '' }
    $cleanCaption = if ($sourceCaption) { $sourceCaption.Trim() } else { '' }

    $supportedEditionRegex = '^(Professional|Enterprise|Education|Server)'
    $unsupportedEditionRegex = '^(Core|Cloud|Starter|Home)'

    $supportedSkus = @(4, 27, 48, 49, 84, 121, 122, 125, 161, 162, 164, 165, 6, 16, 7, 8, 10, 29)
    $unsupportedSkus = @(98, 100, 101, 103, 178, 179)

    $detailParts = New-Object System.Collections.Generic.List[string]
    if ($cleanEditionId) { $detailParts.Add(('EditionID={0}' -f $cleanEditionId)) }
    if ($null -ne $sourceSku) { $detailParts.Add(('SKU={0}' -f $sourceSku)) }
    if ($cleanCaption) { $detailParts.Add(('OS={0}' -f $cleanCaption)) }

    $detail = if ($detailParts.Count -gt 0) { $detailParts -join '; ' } else { 'No OS edition details available' }

    # Step A: Explicitly unsupported check
    $isUnsupported = $false
    $unsupportedReason = ''

    if ($cleanEditionId -and $cleanEditionId -match $unsupportedEditionRegex) {
        $isUnsupported = $true
        $unsupportedReason = ("EditionID '{0}' is a Windows Home/Core/Cloud edition." -f $cleanEditionId)
    }
    elseif ($null -ne $sourceSku -and $unsupportedSkus -contains $sourceSku) {
        $isUnsupported = $true
        $unsupportedReason = ("OperatingSystemSKU '{0}' represents a Windows Home/Core/Cloud edition." -f $sourceSku)
    }
    elseif ($cleanCaption -and $cleanCaption -match '\b(Home|Single Language)\b') {
        $isUnsupported = $true
        $unsupportedReason = ("Operating system '{0}' is a Home edition." -f $cleanCaption)
    }

    if ($isUnsupported) {
        return [pscustomobject]@{
            Supported          = $false
            Status             = 'FAIL'
            EditionID          = $cleanEditionId
            OperatingSystemSKU = $sourceSku
            ProductType        = $sourceProductType
            Caption            = $cleanCaption
            Detail             = $detail
            Message            = ('This Windows edition does not support joining an Active Directory domain: {0} Use Windows 10/11 Pro, Enterprise, or Education.' -f $unsupportedReason)
        }
    }

    # Step B: Confirmed supported check
    $isSupported = $false
    $supportedReason = ''

    if ($cleanEditionId -and $cleanEditionId -match $supportedEditionRegex) {
        $isSupported = $true
        $supportedReason = ("EditionID '{0}' verified." -f $cleanEditionId)
    }
    elseif ($null -ne $sourceSku -and $supportedSkus -contains $sourceSku) {
        $isSupported = $true
        $supportedReason = ("OperatingSystemSKU '{0}' verified." -f $sourceSku)
    }
    elseif ($null -ne $sourceProductType -and $sourceProductType -in @(2, 3)) {
        $isSupported = $true
        $supportedReason = ("ProductType '{0}' (Server/DC) verified." -f $sourceProductType)
    }
    elseif ($cleanCaption -and $cleanCaption -match '\b(Pro\b|Professional|Enterprise|Education|Server)') {
        $isSupported = $true
        $supportedReason = ("Caption '{0}' verified." -f $cleanCaption)
    }

    if ($isSupported) {
        return [pscustomobject]@{
            Supported          = $true
            Status             = 'PASS'
            EditionID          = $cleanEditionId
            OperatingSystemSKU = $sourceSku
            ProductType        = $sourceProductType
            Caption            = $cleanCaption
            Detail             = $detail
            Message            = ('Windows edition supports domain join ({0}).' -f $supportedReason)
        }
    }

    # Step C: Undetermined / Unknown edition
    return [pscustomobject]@{
        Supported          = $false
        Status             = 'FAIL'
        EditionID          = $cleanEditionId
        OperatingSystemSKU = $sourceSku
        ProductType        = $sourceProductType
        Caption            = $cleanCaption
        Detail             = $detail
        Message            = 'Unable to determine Windows edition from Registry (EditionID) or CIM (OperatingSystemSKU/Caption). Cannot confirm Active Directory domain join support. Use Windows 10/11 Pro, Enterprise, or Education.'
    }
}

function Get-LabComputerState {
    [CmdletBinding()]
    param()

    $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $edition = Test-LabWindowsEdition

    $addresses = @()
    try {
        $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.IPAddress -ne '127.0.0.1' } |
            Select-Object IPAddress, PrefixLength, InterfaceIndex, PrefixOrigin)
    }
    catch {
    }

    $dns = @()
    try {
        $dns = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction Stop |
            Select-Object InterfaceIndex, ServerAddresses)
    }
    catch {
    }

    return [pscustomobject]@{
        Name               = $computer.Name
        Domain             = $computer.Domain
        PartOfDomain       = [bool]$computer.PartOfDomain
        DomainRole         = [int]$computer.DomainRole
        OS                 = $os.Caption
        Build              = $os.BuildNumber
        EditionID          = $edition.EditionID
        OperatingSystemSKU = $edition.OperatingSystemSKU
        EditionSupported   = $edition.Supported
        EditionDetail      = $edition.Detail
        IPv4               = $addresses
        Dns                = $dns
    }
}

function Get-LabDomainRoleName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$DomainRole
    )

    switch ($DomainRole) {
        0 { return 'Standalone Workstation' }
        1 { return 'Member Workstation' }
        2 { return 'Standalone Server' }
        3 { return 'Member Server' }
        4 { return 'Backup Domain Controller' }
        5 { return 'Primary Domain Controller' }
        default { return ('Unknown ({0})' -f $DomainRole) }
    }
}

function Write-LabComputerState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $State
    )

    Write-LabLog -Level INFO -Message ('Computer   : {0}' -f $State.Name)
    Write-LabLog -Level INFO -Message ('Domain     : {0}' -f $State.Domain)
    Write-LabLog -Level INFO -Message ('PartOfDomain: {0}' -f $State.PartOfDomain)
    Write-LabLog -Level INFO -Message ('DomainRole : {0}' -f (Get-LabDomainRoleName -DomainRole $State.DomainRole))
    $osInfo = if ($State.PSObject.Properties['EditionID'] -and $State.EditionID) {
        '{0} build {1} ({2})' -f $State.OS, $State.Build, $State.EditionID
    } else {
        '{0} build {1}' -f $State.OS, $State.Build
    }
    Write-LabLog -Level INFO -Message ('OS         : {0}' -f $osInfo)

    foreach ($address in @($State.IPv4)) {
        Write-LabLog -Level INFO -Message ('IPv4       : {0}/{1} ifIndex={2} origin={3}' -f $address.IPAddress, $address.PrefixLength, $address.InterfaceIndex, $address.PrefixOrigin)
    }
    foreach ($entry in @($State.Dns)) {
        $servers = @($entry.ServerAddresses) -join ', '
        Write-LabLog -Level INFO -Message ('DNS        : ifIndex={0} servers={1}' -f $entry.InterfaceIndex, $servers)
    }
}

function Get-LabNetworkAdapter {
    [CmdletBinding()]
    param(
        [string]$MacAddress,
        [string[]]$KnownIPs = @(),
        [switch]$AllowFallback
    )

    $adapters = @(Get-NetAdapter -ErrorAction Stop |
        Where-Object { $_.HardwareInterface -eq $true })

    if ($adapters.Count -eq 0) {
        throw 'No physical network adapter was found.'
    }

    if (-not $MacAddress) {
        if (-not $AllowFallback) {
            throw 'A MAC address is required to identify the lab adapter. Silent fallback is disabled.'
        }
        Write-LabLog -Level WARN -Message 'No MAC address was supplied. Using an explicitly requested fallback adapter selection.'
    }
    else {
        $normalizedMac = ($MacAddress -replace '[:-]', '').ToUpperInvariant()
        $macMatches = @($adapters | Where-Object { ($_.MacAddress -replace '[:-]', '').ToUpperInvariant() -eq $normalizedMac })
        if ($macMatches.Count -eq 1) {
            if ($macMatches[0].Status -ne 'Up') {
                throw ("Adapter {0} matches MAC {1} but its status is {2}; expected Up. Check the VM network adapter." -f $macMatches[0].Name, $MacAddress, $macMatches[0].Status)
            }
            return $macMatches[0]
        }
        if ($macMatches.Count -gt 1) {
            throw ("Multiple adapters match MAC {0}." -f $MacAddress)
        }
        if (-not $AllowFallback) {
            $names = ($adapters | ForEach-Object { '{0} [{1}] ({2})' -f $_.Name, $_.MacAddress, $_.Status }) -join '; '
            throw ("No adapter matches MAC {0}. Candidate adapters: {1}. Refusing a silent fallback; verify CONFIG\LabConfig.psd1 and the VM network adapter." -f $MacAddress, $names)
        }
        Write-LabLog -Level WARN -Message ('No adapter matches MAC {0}. Using the explicitly requested fallback adapter selection.' -f $MacAddress)
    }

    $upAdapters = @($adapters | Where-Object { $_.Status -eq 'Up' })
    foreach ($ip in @($KnownIPs)) {
        if (-not $ip) { continue }
        $found = @()
        foreach ($adapter in $upAdapters) {
            $exists = @(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -eq $ip })
            if ($exists.Count -gt 0) {
                $found += $adapter
            }
        }
        if ($found.Count -eq 1) {
            Write-LabLog -Level WARN -Message ('Fallback selected adapter {0} because it has IPv4 {1}.' -f $found[0].Name, $ip)
            return $found[0]
        }
        if ($found.Count -gt 1) {
            throw ("Multiple Up adapters have IPv4 {0}; fallback is ambiguous." -f $ip)
        }
    }

    if ($upAdapters.Count -eq 1) {
        Write-LabLog -Level WARN -Message ('Fallback selected the only Up physical adapter: {0}.' -f $upAdapters[0].Name)
        return $upAdapters[0]
    }

    $names = ($upAdapters | ForEach-Object { '{0} [{1}]' -f $_.Name, $_.MacAddress }) -join '; '
    throw ("Cannot identify the target adapter. Candidates: {0}. Check MacAddress in CONFIG\LabConfig.psd1." -f $names)
}

function Get-LabInterfaceAddresses {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$InterfaceIndex
    )

    return @(Get-NetIPAddress -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -ne '127.0.0.1' })
}

function Remove-LabDefaultRoute {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$InterfaceIndex
    )

    $routes = @(Get-NetRoute -InterfaceIndex $InterfaceIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
    if ($routes.Count -eq 0) {
        Write-LabLog -Level INFO -Message 'No default route present on the target adapter (expected: configuration has no gateway).'
        return
    }

    foreach ($route in $routes) {
        Write-LabLog -Level WARN -Message ('Removing default route {0} via {1} on ifIndex {2}.' -f $route.DestinationPrefix, $route.NextHop, $InterfaceIndex)
        Remove-NetRoute -InputObject $route -Confirm:$false -ErrorAction Stop
    }
}

function Set-LabStaticIPv4 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$InterfaceIndex,
        [Parameter(Mandatory = $true)]
        [string]$IPAddress,
        [Parameter(Mandatory = $true)]
        [int]$PrefixLength,
        [string]$Gateway,
        [string[]]$DnsServers = @()
    )

    $adapter = Get-NetAdapter -InterfaceIndex $InterfaceIndex -ErrorAction Stop
    $mask = Get-LabSubnetMaskString -PrefixLength $PrefixLength
    $gatewayText = if ($Gateway) { $Gateway } else { 'none' }

    Write-LabLog -Level STEP -Message ('Setting static IPv4 {0}/{1} on adapter {2} (gateway: {3}).' -f $IPAddress, $PrefixLength, $adapter.Name, $gatewayText)
    Write-LabLog -Level WARN -Message 'The existing IPv4 address on this adapter will be replaced. Use the VMware console, not RDP.'

    $netshArgs = @('interface', 'ipv4', 'set', 'address', ('name="{0}"' -f $adapter.Name), 'static', $IPAddress, $mask)
    if ($Gateway) {
        $netshArgs += $Gateway
    }

    $output = & netsh.exe @netshArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ('netsh failed to set the IPv4 address (exit {0}): {1}' -f $LASTEXITCODE, ($output -join ' '))
    }

    $addressReady = Wait-LabCondition -Condition {
        $addresses = @(Get-LabInterfaceAddresses -InterfaceIndex $InterfaceIndex)
        $target = @($addresses | Where-Object { $_.IPAddress -eq $IPAddress -and $_.PrefixLength -eq $PrefixLength })
        $unexpected = @($addresses | Where-Object {
                $_.IPAddress -ne $IPAddress -and
                $_.PrefixOrigin -ne 'WellKnown' -and
                -not $_.IPAddress.StartsWith('169.254.')
            })
        return ($target.Count -eq 1 -and $unexpected.Count -eq 0)
    } -TimeoutSeconds 15 -IntervalSeconds 1 -Description ('static IPv4 {0}/{1}' -f $IPAddress, $PrefixLength)

    if (-not $addressReady) {
        $actual = @(Get-LabInterfaceAddresses -InterfaceIndex $InterfaceIndex | ForEach-Object { '{0}/{1} ({2})' -f $_.IPAddress, $_.PrefixLength, $_.PrefixOrigin }) -join ', '
        throw ('IPv4 {0}/{1} was not cleanly applied to adapter {2}. Current addresses: {3}' -f $IPAddress, $PrefixLength, $adapter.Name, $actual)
    }

    if ($DnsServers -and @($DnsServers).Count -gt 0) {
        Set-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -ServerAddresses $DnsServers -ErrorAction Stop
        Write-LabLog -Level INFO -Message ('DNS client servers set to: {0}' -f (@($DnsServers) -join ', '))

        $expectedDns = (@($DnsServers) | Sort-Object) -join ','
        $dnsReady = Wait-LabCondition -Condition {
            $dnsObject = Get-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
            $actualDns = @()
            if ($dnsObject) { $actualDns = @($dnsObject.ServerAddresses) }
            return (((@($actualDns) | Sort-Object) -join ',') -eq $expectedDns)
        } -TimeoutSeconds 10 -IntervalSeconds 1 -Description 'static DNS configuration'
        if (-not $dnsReady) {
            throw ('DNS servers {0} were not cleanly applied to adapter {1}.' -f (@($DnsServers) -join ', '), $adapter.Name)
        }
    }
    else {
        Set-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -ResetServerAddresses -ErrorAction Stop
        Write-LabLog -Level INFO -Message 'DNS client servers reset to DHCP/empty.'
    }

    if (-not $Gateway) {
        Remove-LabDefaultRoute -InterfaceIndex $InterfaceIndex
    }
}

function Get-LabDnsClientServers {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$InterfaceIndex
    )

    $dnsObject = Get-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if (-not $dnsObject) {
        return @()
    }
    return @($dnsObject.ServerAddresses)
}

function Set-LabDnsClientServers {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$InterfaceIndex,
        [Parameter(Mandatory = $true)]
        [string[]]$DnsServers,
        [int]$TimeoutSeconds = 15
    )

    $expected = @($DnsServers)
    if ($expected.Count -eq 0) {
        throw 'At least one DNS server address is required.'
    }

    $expectedText = ($expected | Sort-Object) -join ','
    $current = @(Get-LabDnsClientServers -InterfaceIndex $InterfaceIndex)
    if ((($current | Sort-Object) -join ',') -ne $expectedText) {
        Set-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -ServerAddresses $expected -ErrorAction Stop
        Write-LabLog -Level INFO -Message ('DNS client servers set to: {0}' -f ($expected -join ', '))
    }
    else {
        Write-LabLog -Level INFO -Message ('DNS client servers already set to: {0}' -f ($expected -join ', '))
    }

    $ready = Wait-LabCondition -Condition {
        $actual = @(Get-LabDnsClientServers -InterfaceIndex $InterfaceIndex)
        return ((($actual | Sort-Object) -join ',') -eq $expectedText)
    } -TimeoutSeconds $TimeoutSeconds -IntervalSeconds 1 -Description 'DNS client configuration'

    if (-not $ready) {
        $actual = @(Get-LabDnsClientServers -InterfaceIndex $InterfaceIndex)
        throw ('DNS client servers were not applied. Expected: {0}. Actual: {1}.' -f ($expected -join ', '), ($actual -join ', '))
    }

    try { Clear-DnsClientCache -ErrorAction SilentlyContinue } catch { }
    return $true
}

function Get-LabDhcpState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$InterfaceIndex
    )

    $interface = Get-NetIPInterface -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop
    $addresses = @(Get-LabInterfaceAddresses -InterfaceIndex $InterfaceIndex | Where-Object { $_.PrefixOrigin -eq 'Dhcp' })

    return [pscustomobject]@{
        DhcpEnabled = ($interface.Dhcp -eq 'Enabled')
        Addresses   = $addresses
    }
}

function Invoke-LabIpconfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('release', 'renew')]
        [string]$Action,
        [Parameter(Mandatory = $true)]
        [string]$InterfaceAlias,
        [Parameter(Mandatory = $true)]
        [int]$InterfaceIndex
    )

    $output = & ipconfig.exe ('/{0}' -f $Action) $InterfaceAlias 2>&1
    $exitCode = $LASTEXITCODE
    $text = (@($output | ForEach-Object { $_.ToString().Trim() }) -join ' | ')
    Write-LabLog -Level INFO -Message ('ipconfig /{0} adapter="{1}" ifIndex={2} exit={3}: {4}' -f $Action, $InterfaceAlias, $InterfaceIndex, $exitCode, $text)
    if ($exitCode -ne 0) {
        throw ('ipconfig /{0} failed for adapter "{1}" (ifIndex {2}) with exit code {3}.' -f $Action, $InterfaceAlias, $InterfaceIndex, $exitCode)
    }
}

function Get-LabDhcpServerAddress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$InterfaceIndex
    )

    $nic = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter ('InterfaceIndex = {0}' -f $InterfaceIndex) -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $nic) {
        return $null
    }
    $dhcpServer = [string]$nic.DHCPServer
    if ([string]::IsNullOrWhiteSpace($dhcpServer)) {
        return $null
    }
    return $dhcpServer
}

function Get-LabConnectionDnsSuffix {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$InterfaceIndex
    )

    $client = Get-DnsClient -InterfaceIndex $InterfaceIndex -ErrorAction SilentlyContinue
    if (-not $client) {
        return ''
    }
    return ([string]$client.ConnectionSpecificSuffix).TrimEnd('.')
}

function Enable-LabDhcpClient {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$InterfaceIndex,
        [Parameter(Mandatory = $true)]
        [string]$ExpectedPrefix,
        [int]$ExpectedPrefixLength = 24,
        [int]$TimeoutSeconds = 90
    )

    $adapter = Get-NetAdapter -InterfaceIndex $InterfaceIndex -ErrorAction Stop
    $dhcpService = Get-Service -Name Dhcp -ErrorAction SilentlyContinue
    if ($dhcpService -and $dhcpService.Status -ne 'Running') {
        Start-Service -Name Dhcp -ErrorAction Stop
    }

    Write-LabLog -Level STEP -Message ('Enabling DHCP on adapter {0}.' -f $adapter.Name)
    $output = & netsh.exe interface ipv4 set address ('name="{0}"' -f $adapter.Name) source=dhcp 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ('Failed to enable DHCP on {0} (exit {1}): {2}' -f $adapter.Name, $LASTEXITCODE, ($output -join ' '))
    }

    $dnsOutput = & netsh.exe interface ipv4 set dnsservers ('name="{0}"' -f $adapter.Name) source=dhcp 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ('Failed to set DNS source to DHCP on {0} (exit {1}): {2}' -f $adapter.Name, $LASTEXITCODE, ($dnsOutput -join ' '))
    }

    try {
        Invoke-LabIpconfig -Action renew -InterfaceAlias $adapter.Name -InterfaceIndex $InterfaceIndex
    }
    catch {
        Write-LabLog -Level WARN -Message ('Initial ipconfig /renew returned non-zero ({0}); entering wait loop for lease.' -f $_.Exception.Message)
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Seconds 3
        $dhcpState = Get-LabDhcpState -InterfaceIndex $InterfaceIndex
        $lease = @($dhcpState.Addresses | Where-Object {
                $_.PrefixOrigin -eq 'Dhcp' -and
                -not $_.IPAddress.StartsWith('169.254.') -and
                (Test-LabSameSubnet -IPAddressA $_.IPAddress -IPAddressB $ExpectedPrefix -PrefixLength $ExpectedPrefixLength)
            })
        if ($dhcpState.DhcpEnabled -and $lease.Count -gt 0) {
            return $lease[0]
        }
        Write-LabLog -Level INFO -Message 'Waiting for a DHCP lease...'
    } while ((Get-Date) -lt $deadline)

    return $null
}

function Get-LabScopeId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$IPAddress,
        [Parameter(Mandatory = $true)]
        [int]$PrefixLength
    )

    $network = Get-LabNetworkBytes -IPAddress $IPAddress -PrefixLength $PrefixLength
    return ($network -join '.')
}

function Test-LabTcpPort {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName,
        [Parameter(Mandatory = $true)]
        [int]$Port,
        [int]$TimeoutMilliseconds = 3000
    )

    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $task = $client.ConnectAsync($ComputerName, $Port)
        if ($task.Wait($TimeoutMilliseconds)) {
            return $client.Connected
        }
        return $false
    }
    catch {
        return $false
    }
    finally {
        if ($client) { $client.Close() }
    }
}

function Wait-LabCondition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Condition,
        [int]$TimeoutSeconds = 120,
        [int]$IntervalSeconds = 5,
        [string]$Description = 'condition'
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            if (& $Condition) {
                return $true
            }
        }
        catch {
        }
        Start-Sleep -Seconds $IntervalSeconds
    } while ((Get-Date) -lt $deadline)

    Write-LabLog -Level WARN -Message ('Timed out waiting for {0} after {1} seconds.' -f $Description, $TimeoutSeconds)
    return $false
}

function Add-LabCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [ValidateSet('PASS', 'FAIL', 'WARN', 'INFO')]
        [string]$Status,
        [string]$Detail = ''
    )

    $message = '[{0}] {1}' -f $Status, $Name
    if ($Detail) {
        $message = '{0} - {1}' -f $message, $Detail
    }

    switch ($Status) {
        'PASS' { Write-Host $message -ForegroundColor Green }
        'WARN' { Write-Host $message -ForegroundColor Yellow }
        'FAIL' { Write-Host $message -ForegroundColor Red }
        default { Write-Host $message -ForegroundColor Gray }
    }

    if ($script:LabLogFile) {
        try {
            Add-Content -LiteralPath $script:LabLogFile -Value ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $message) -Encoding UTF8 -ErrorAction Stop
        }
        catch {
        }
    }

    [void]$script:LabChecks.Add([pscustomobject]@{
        Name   = $Name
        Status = $Status
        Detail = $Detail
    })
}

function Get-LabCheckStatistics {
    [CmdletBinding()]
    param()

    return [pscustomobject]@{
        Pass = @($script:LabChecks | Where-Object { $_.Status -eq 'PASS' }).Count
        Warn = @($script:LabChecks | Where-Object { $_.Status -eq 'WARN' }).Count
        Fail = @($script:LabChecks | Where-Object { $_.Status -eq 'FAIL' }).Count
        Info = @($script:LabChecks | Where-Object { $_.Status -eq 'INFO' }).Count
    }
}

function Write-LabCheckSummary {
    [CmdletBinding()]
    param()

    $statistics = Get-LabCheckStatistics
    $pass = $statistics.Pass
    $warn = $statistics.Warn
    $fail = $statistics.Fail
    $info = $statistics.Info

    Write-LabLog -Level STEP -Message ('Summary: PASS={0} WARN={1} FAIL={2} INFO={3}' -f $pass, $warn, $fail, $info)

    if ($fail -gt 0) {
        Write-LabLog -Level ERROR -Message 'RESULT: FAIL - review the failed checks above.'
        return 'FAIL'
    }
    if ($warn -gt 0) {
        Write-LabLog -Level WARN -Message 'RESULT: PASS WITH WARNINGS - review the warnings above.'
        return 'WARN'
    }
    Write-LabLog -Level SUCCESS -Message 'RESULT: PASS'
    return 'PASS'
}

function Import-LabRequiredModule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [string]$PrerequisiteMessage = ''
    )

    if (Get-Module -Name $Name) {
        return
    }
    if (-not (Get-Module -ListAvailable -Name $Name)) {
        throw ('Module {0} is not available. {1}' -f $Name, $PrerequisiteMessage)
    }
    Import-Module -Name $Name -ErrorAction Stop
    Write-LabLog -Level INFO -Message ('Module imported: {0}' -f $Name)
}

function Test-LabSecureStringEqual {
    [CmdletBinding()]
    param(
        [securestring]$SecureStringA,
        [securestring]$SecureStringB
    )

    if ($null -eq $SecureStringA -or $null -eq $SecureStringB) {
        return $false
    }

    $first = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureStringA)
    $second = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureStringB)
    try {
        $plainA = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($first)
        $plainB = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($second)
        return ($plainA -ceq $plainB)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($first)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($second)
    }
}

function Read-LabSecurePassword {
    [CmdletBinding()]
    param(
        [string]$Prompt = 'Password',
        [int]$MinimumLength = 7,
        [switch]$RequireComplexity
    )

    $first = Read-Host -Prompt $Prompt -AsSecureString
    $second = Read-Host -Prompt ('{0} (confirm)' -f $Prompt) -AsSecureString

    if (-not (Test-LabSecureStringEqual -SecureStringA $first -SecureStringB $second)) {
        throw 'The two passwords do not match. No changes were made.'
    }
    if ($first.Length -lt $MinimumLength) {
        throw ('The password must be at least {0} characters long.' -f $MinimumLength)
    }

    if ($RequireComplexity) {
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($first)
        try {
            $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            $categories = 0
            if ($plain -cmatch '[A-Z]') { $categories++ }
            if ($plain -cmatch '[a-z]') { $categories++ }
            if ($plain -cmatch '[0-9]') { $categories++ }
            if ($plain -match '[^A-Za-z0-9]') { $categories++ }
            if ($categories -lt 3) {
                throw 'The password must contain at least 3 of these 4 categories: uppercase, lowercase, digit, symbol.'
            }
        }
        finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }

    return $first
}

function Confirm-LabAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [Parameter(Mandatory = $true)]
        [string]$ExpectedWord
    )

    Write-LabLog -Level WARN -Message $Message
    $answer = Read-Host -Prompt ("Type '{0}' to continue (anything else aborts)" -f $ExpectedWord)
    if ($answer -cne $ExpectedWord) {
        throw ("Confirmation failed: expected exactly '{0}'. The requested action was not started." -f $ExpectedWord)
    }
}

Export-ModuleMember -Function *

