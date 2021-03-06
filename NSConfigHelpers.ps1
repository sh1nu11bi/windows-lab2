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
        [Parameter(Mandatory)] [String]$ExternalFQDN,
        [Parameter(Mandatory)] [String]$InternalFQDN,
        [String]$InternalIPAddress,
        [String]$InternalProtocol = 'HTTP',
        [String]$CertificateName = $ExternalFQDN,
        [String]$AuthenticationHost,
        [String]$AuthenticationVServerName,
        [String]$ContentSwitchingName,
        [String]$Priority,
        [String]$Type = ''
    )
    if ($InternalFQDN) {
        $InternalId = $InternalFQDN
    } else {
        $InternalId = $InternalIPAddress
    }
    if ($InternalProtocol -eq 'SSL') {
        $Port = 443
    } else {
        $Port = 80
    }

    $VServerName                = "vsrv-$ExternalFQDN"
    $ServerName                 = "srv-$InternalId"
    $ServiceGroupName           = "svg-$ExternalFQDN"
    $ContentSwitchingPolicyName = "cs-pol-$ExternalFQDN"

    Write-Verbose "  -- Creating reverse proxy $ExternalFQDN -> $InternalId..."
    if (Get-NSLBVirtualServer -Name $VServerName -ErrorAction SilentlyContinue) {
        Write-Verbose "  -- Already created: skipping."
        return
    }

    Write-Verbose "  ---- Creating LB Servers '$ServerName'..."
    if ($InternalIPAddress) {
        New-NSLBServer -Name $ServerName -IPAddress $InternalIPAddress
    } else {
        New-NSLBServer -Name $ServerName -Domain $InternalFQDN
    }
    Enable-NSLBServer -Name $ServerName -Force
    New-NSLBServiceGroup -Name $ServiceGroupName -Protocol $InternalProtocol
    if ($InternalProtocol -eq "SSL") {
        # "sslservicegroup":{"servicegroupname":"svg-sts.extlab.local","sessreuse":"ENABLED","sesstimeout":"300","serverauth":"DISABLED",
        # "commonname":"sts.extlab.local","snienable":"ENABLED","sendclosenotify":"YES","ssl3":"DISABLED",
        # "tls1":"ENABLED","tls11":"ENABLED","tls12":"ENABLED"}
        Write-Verbose "  ------ Activating internal SNI..."
        Invoke-Nitro -Type sslservicegroup -Method PUT -Payload @{
                servicegroupname   = $ServiceGroupName
                commonname         = $InternalFQDN
                snienable          = "ENABLED"
            } -Force
    }
    New-NSLBServiceGroupMember -Name svg-$ExternalFQDN -ServerName $ServerName -Port $Port

    Write-Verbose "  ---- Creating LB VServer '$VServerName'..."
    New-NSLBVirtualServer -Name $VServerName -NonAddressable -ServiceType SSL
    Add-NSLBVirtualServerBinding -VirtualServerName $VServerName -ServiceGroupName svg-$ExternalFQDN
    Enable-NSLBVirtualServer -Name $VServerName -Force


    # We need to bind the certificate to the virtual server even if it is also
    # bound to the CS server
    Write-Verbose "  ---- Binding certificate '$CertificateName' to $VServerName..."
    Add-NSLBSSLVirtualServerCertificateBinding -VirtualServerName $VServerName -Certificate $CertificateName

    Write-Verbose "  ---- Binding certificate '$CertificateName' to $ContentSwitchingName..."
    Add-NSLBSSLVirtualServerCertificateBinding -VirtualServerName $ContentSwitchingName -Certificate $CertificateName -SniCert $True

    if ($InternalFQDN) {
        Write-Verbose "  ---- Adding policies rewrite policy: $ExternalFQDN -> $InternalFQDN ..."
        New-NSRewriteAction -Name "act-proxy-host-$InternalFQDN" -Type Replace -Target 'HTTP.REQ.HOSTNAME' -Expression "`"$InternalFQDN`""
        New-NSRewritePolicy -Name "pol-proxy-host-$InternalFQDN" -ActionName "act-proxy-host-$InternalFQDN" -Rule "true"
        Add-NSLBVirtualServerRewritePolicyBinding -VirtualServerName $VServerName -PolicyName "pol-proxy-host-$InternalFQDN" `
            -BindPoint Request -Priority 100
    }

    if (-not (Invoke-Nitro -Method GET -Type cspolicy -Resource $ContentSwitchingPolicyName -ErrorAction SilentlyContinue)) {
        Write-Verbose "  ---- Creating content switching policy for '$ExternalFQDN'... "
        Invoke-Nitro -Method POST -Type cspolicy -Payload @{
                # "cspolicy":{"policyname":"cs-pol-toto","rule":"HTTP.REQ.HOSTNAME.EQ(\"www.extlab.local\")"}
                policyname  = $ContentSwitchingPolicyName
                rule        = "HTTP.REQ.HOSTNAME.EQ(`"$ExternalFQDN`")"
            } -Action add -Force
    }

    if (-not (Invoke-Nitro -Method GET -Type csvserver_cspolicy_binding -ErrorAction SilentlyContinue)) {
        Write-Verbose "  ---- Creating content switching binding '$ContentSwitchingName' <- '$VServerName' ($Priority)... "
        Invoke-Nitro -Method POST -Type csvserver_cspolicy_binding -Payload @{
                # "csvserver_cspolicy_binding":{"policyname":"cs-pol-toto","priority":"100","gotopriorityexpression":"END","targetlbvserver":"vsrv-www.extlab.local","name":"cs-lab",
                #"bindpoint":"REQUEST"}}
                policyname      = $ContentSwitchingPolicyName
                targetlbvserver = $VServerName
                name            = $ContentSwitchingName
                priority        = $Priority
            } -Action add -Force
    }

    if ($AuthenticationHost) {
        Write-Verbose "  ---- Setting up authentication for $ExternalFQDN..."
        Invoke-Nitro -Type lbvserver -Method PUT -Payload @{
                name               = $VServerName
                authenticationhost = $AuthenticationHost
                authnvsname        = $AuthenticationVServerName
                authentication     = "ON"
                authn401           = "OFF"
            } -Force -Session $Session   
    }
}

function New-AAAConfig {
    Param(
        [Parameter(Mandatory)] [String]$FQDN,
        [String]$CertificateName = $FQDN,
        [Parameter(Mandatory)] [String]$SAMLCertificate,
        [String]$DomainName       = 'extlab.local',
        [String]$ADFSFQDN         = "sts.$DomainName"
    )
    $Name           = "aaa-vsrv-$FQDN"
    $SAMLPolicyName = "pol-saml-$ADFSFQDN"
    $SAMLActionName = "act-saml-$ADFSFQDN"
    Write-Verbose "  -- Setting up AAA..."

    if (-not (Invoke-Nitro -Method GET -Type authenticationvserver -Resource $Name -ErrorAction SilentlyContinue)) {
        Write-Verbose "  ---- Setting up authentication server '$Name'..."
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
        Write-Verbose "  ---- Creating SAML authentication action..."
        Invoke-Nitro -Method POST -Type authenticationsamlaction  -Payload @{
                name                           = $SAMLActionName
                samlidpcertname                = $SAMLCertificate
                samlredirecturl                = "https://$ADFSFQDN/adfs/ls"
                #samlsigningcertname            = $CertificateName
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
   if (-not ((Invoke-Nitro -Method GET -Type authenticationvserver_authenticationsamlpolicy_binding -Resource $Name).psobject.Properties.Name -contains 'authenticationvserver_authenticationsamlpolicy_binding')) {
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