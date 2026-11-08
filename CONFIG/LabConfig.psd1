@{
    LabName = 'EAUT-AD-DHCP-LAB'

    Server = @{
        Name              = 'EAUT-SRV12'
        BaselineName      = 'WIN-CFQCN24HB2F'
        MacAddress        = '00-0C-29-91-A4-3B'
        BaselineIPAddress = '192.168.1.4'
        IPAddress         = '192.168.63.2'
        PrefixLength      = 24
        SubnetMask        = '255.255.255.0'
        Gateway           = $null
        DnsServers        = @('192.168.63.2')
    }

    Client = @{
        Name              = 'WRK01'
        BaselineName      = 'DESKTOP-JE6RBJV'
        MacAddress        = '00-0C-29-7C-0C-67'
        BaselineIPAddress = '192.168.1.10'
        StaticIPAddress   = '192.168.63.10'
        PrefixLength      = 24
        SubnetMask        = '255.255.255.0'
        Gateway           = $null
        DnsServers        = @('192.168.63.2')
    }

    Domain = @{
        DnsName             = 'binhnd363.edu.vn'
        NetbiosName         = 'BINHND363'
        ForestMode          = 'WinThreshold'
        DomainMode          = 'WinThreshold'
        InstallDns          = $true
        CreateDnsDelegation = $false
    }

    Dhcp = @{
        ScopeName   = 'EAUT-LAB-63'
        StartRange  = '192.168.63.100'
        EndRange    = '192.168.63.200'
        LeaseDays   = 8
        Router      = $null
        DnsServers  = @('192.168.63.2')
        DnsDomain   = 'binhnd363.edu.vn'
        Reservation = $null
    }

    Paths = @{
        LogDirectory = 'LOGS'
    }
}
