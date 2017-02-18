function Connect-NetscalerInstance {
    Param(
        $NSIP,
        $Username,
        $Password
    )
    Write-Verbose "Connecting to Netscaler on IP $NSip..."
    $SecurePassword = ConvertTo-SecureString $Password -AsPlainText -Force
    $Credential = New-Object System.Management.Automation.PSCredential ($Username, $SecurePassword)
    return Connect-Netscaler -Hostname $Nsip -Credential $Credential -PassThru
}

function Import-Certificate {
    Param(
        [String]$CertificateName,
        [String]$LocalFilename,
        [String]$Filename,
        [String]$Password  
    )
    if (Get-NSSystemFile -FileLocation '/nsconfig/ssl' | Where Filename -eq $Filename) {
        Write-Verbose "  ---- Certificate '$CertificateName' is already present."
    } else {    
        Write-Verbose "  ---- Uploading certificate '$CertificateName'..."
        Add-NSSystemFile -Path $LocalFilename -FileLocation '/nsconfig/ssl' -Filename $Filename    
    }
    if (-not (Get-NSSSLCertificate -Name $CertificateName -ErrorAction SilentlyContinue)) {
        Write-Verbose "  ---- Adding keypair... "
        if ($Password) {
            Add-NSCertKeyPair -CertKeyName $CertificateName -CertPath $Filename -KeyPath $Filename -CertKeyFormat PEM -Password (
                ConvertTo-SecureString -AsPlainText -Force -String $Password)
        } else {
            Add-NSCertKeyPair -CertKeyName $CertificateName -CertPath $Filename -CertKeyFormat DER
        }
    }
}

function New-ReverseProxy {
    Param(
        [String]$IPAddress,
        [String]$ExternalFQDN,
        [String]$InternalFQDN,
        [String]$CertificateName = $ExternalFQDN,
        [String]$AuthenticationHost,
        [String]$AuthenticationVServerName               
    )
    $VServerName = "vsrv-$ExternalFQDN"
    $ServerName = "srv-$InternalFQDN"
    
    Write-Verbose "  -- Creating reverse proxy $ExternalFQDN -> $InternalFQDN..."
    New-NSLBServer -Name $ServerName -Domain $InternalFQDN
    Enable-NSLBServer -Name $ServerName -Force
    New-NSLBServiceGroup -Name svg-$ExternalFQDN -Protocol HTTP
    New-NSLBServiceGroupMember -Name svg-$ExternalFQDN -ServerName $ServerName

    New-NSLBVirtualServer -Name $VServerName -IPAddress $IPAddress -ServiceType SSL -Port 443
    Add-NSLBVirtualServerBinding -VirtualServerName $VServerName -ServiceGroupName svg-$ExternalFQDN
    Enable-NSLBVirtualServer -Name $VServerName -Force

    Add-NSLBSSLVirtualServerCertificateBinding -VirtualServerName $VServerName -Certificate $CertificateName
    
    New-NSRewriteAction -Name "act-proxy-host-$InternalFQDN" -Type Replace -Target 'HTTP.REQ.HOSTNAME' -Expression "`"$InternalFQDN`""    
    New-NSRewritePolicy -Name "pol-proxy-host-$InternalFQDN" -ActionName "act-proxy-host-$InternalFQDN" -Rule "true"
    Add-NSLBVirtualServerRewritePolicyBinding -VirtualServerName $VServerName -PolicyName "pol-proxy-host-$InternalFQDN" `
        -BindPoint Request -Priority 1    

    Write-Verbose "  ---- Setting up authentication for $ExternalFQDN..."
    Invoke-Nitro -Type lbvserver -Method PUT -Payload @{ 
            name               = $VServerName
            authenticationhost = $AuthenticationHost
            authnvsname        = $AuthenticationVServerName
            authentication     = "ON"
            authn401           = "OFF"
        } -Force
}

function New-AAAConfig {
    Param(
        [String]$Name             = "aaa-server",
        [String]$CertificateName  = "aaa.extlab.local",
        [String]$IPAddress        = "172.16.124.13",
        [String]$Port             = "443",
        [String]$SAMLCertificate  = 'adfs_token_signing',
        [String]$DomainName       = 'extlab.local',
        [String]$ADFSFQDN         = "adfs.$DomainName"
    )
    $SAMLPolicyName = "pol-saml-$ADFSFQDN"
    $SAMLActionName = "act-saml-$ADFSFQDN"
    Write-Verbose "  -- Setting up AAA..."

    if (-not (Invoke-Nitro -Method GET -Type authenticationvserver -Resource $Name -ErrorAction SilentlyContinue)) {
        Write-Verbose "  ---- Setting up authentication server..."
        Invoke-Nitro -Type authenticationvserver -Method POST -Payload @{ 
                name                 = $Name
               # ipv46                = $IPAddress
               # port                 = $Port
                servicetype          = "SSL"
                authenticationdomain = $DomainName
                authentication       = "ON"
                state                = "ENABLED"        
            } -Action Add -Force
    }

    if (-not (Invoke-Nitro -Method GET -Type authenticationsamlaction -Resource $SAMLActionName -ErrorAction SilentlyContinue)) {
        Write-Verbose "  ---- Creating SAML authentication action"
        Invoke-Nitro -Method POST -Type authenticationsamlaction  -Payload @{
                name                           = $SAMLActionName
                samlidpcertname                = $SAMLCertificate
                samlredirecturl                = "https://$ADFSFQDN/adfs/ls"
                samlsigningcertname            = $CertificateName
                samlissuername                 = "Netscaler"
                samlrejectunsignedassertion    = "ON"
                samlbinding                    = "POST"
                skewtime                       = "5"
                samltwofactor                  = "OFF"
                samlacsindex                   = "255"
                attributeconsumingserviceindex = "255"
                requestedauthncontext          = "exact"
                signaturealg                   = "RSA-SHA256"
                digestmethod                   = "SHA256"
                sendthumbprint                 = "OFF"
                enforceusername                = "ON"   
            } -Action add -Force
    }
    if (-not (Invoke-Nitro -Method GET -Type authenticationsamlpolicy -Resource $SAMLPolicyName -ErrorAction SilentlyContinue)) {
        Write-Verbose "  ---- Creating SAML authentication policy..."
        Invoke-Nitro -Method POST -Type authenticationsamlpolicy -Payload @{
                name      = $SAMLPolicyName
                reqaction = $SAMLActionName
                rule      = "ns_true"
            } -Action add -Force
    }
    if (-not (Invoke-Nitro -Method GET -Type vpnvserver_authenticationsamlpolicy_binding -Resource $Name -ErrorAction SilentlyContinue)) {
        Write-Verbose "  ---- Binding authentication policy... "    
        Invoke-Nitro -Method POST -Type authenticationvserver_authenticationsamlpolicy_binding -Payload @{
                policy    = $SAMLPolicyName
                name      = $Name
                priority  = "100"
                secondary = "false"
            } -Action add -Force
    }
    if (-not (Get-NSLBSSLVirtualServerCertificateBinding -VirtualServerName $Name -ErrorAction SilentlyContinue)) {
        Write-Verbose "  ---- Binding certificat to AAA server... "    
        Add-NSLBSSLVirtualServerCertificateBinding -VirtualServerName $Name -Certificate $CertificateName   
    }
}