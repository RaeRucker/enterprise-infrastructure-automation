function Get-TlsCertificateExpiry {
    <#
    .SYNOPSIS
        Connects to TLS endpoints and reports the presented certificate's expiry and validity. Read-only.
    .DESCRIPTION
        Checks the certificate a service actually presents (not what's in a certificate
        store), which is what clients see. Works for any TLS service: HTTPS, LDAPS (636),
        RDP gateway, SMTP with implicit TLS (465), and so on.

        Status: OK, Warning (within CertificateWarningDays), Critical (within
        CertificateCriticalDays or already expired), NameMismatch, Untrusted,
        or Unreachable.
    .PARAMETER Endpoint
        host or host:port. Port defaults to 443.
    .EXAMPLE
        Get-TlsCertificateExpiry -Endpoint portal.example.com, dc01.corp.example:636
    .OUTPUTS
        InfraOps.TlsCertificate
    .NOTES
        Cross-platform (uses .NET SslStream). The validation callback records chain and
        name errors instead of failing, so an expired or untrusted certificate is still
        reported.
    #>
    [CmdletBinding()]
    [OutputType('InfraOps.TlsCertificate')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [ValidatePattern('^[A-Za-z0-9.-]+(:\d{1,5})?$')]
        [string[]] $Endpoint,

        [ValidateRange(1, 60)]
        [int] $TimeoutSeconds = 10
    )

    begin { $t = (Get-InfraOpsConfig).Thresholds }

    process {
        foreach ($e in $Endpoint) {
            $hostName, $port = $e.Split(':')
            $port = if ($port) { [int]$port } else { 443 }

            try {
                $cert = Get-InfraRemoteCertificate -HostName $hostName -Port $port -TimeoutSeconds $TimeoutSeconds
            }
            catch {
                Write-InfraLog -Level Warning -Message "Cannot reach ${hostName}:${port}: $($_.Exception.Message)"
                [pscustomobject]@{
                    PSTypeName = 'InfraOps.TlsCertificate'; Endpoint = "${hostName}:${port}"; Status = 'Unreachable'
                    Subject = $null; Issuer = $null; NotAfter = $null; DaysRemaining = $null; Thumbprint = $null; PolicyErrors = $_.Exception.Message
                }
                continue
            }

            $days = [int][math]::Floor(($cert.NotAfter - (Get-Date)).TotalDays)
            $status = switch ($true) {
                { $days -le $t.CertificateCriticalDays }       { 'Critical'; break }
                { $cert.PolicyErrors -match 'RemoteCertificateNameMismatch' } { 'NameMismatch'; break }
                { $cert.PolicyErrors -match 'RemoteCertificateChainErrors' }  { 'Untrusted'; break }
                { $days -le $t.CertificateWarningDays }        { 'Warning'; break }
                default                                        { 'OK' }
            }

            [pscustomobject]@{
                PSTypeName    = 'InfraOps.TlsCertificate'
                Endpoint      = "${hostName}:${port}"
                Status        = $status
                Subject       = $cert.Subject
                Issuer        = $cert.Issuer
                NotAfter      = $cert.NotAfter
                DaysRemaining = $days
                Thumbprint    = $cert.Thumbprint
                PolicyErrors  = $cert.PolicyErrors
            }
        }
    }
}

function Get-InfraRemoteCertificate {
    <# Performs the TLS handshake and returns certificate details. Mocked in unit tests. #>
    [CmdletBinding()]
    param([string] $HostName, [int] $Port, [int] $TimeoutSeconds)

    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        if (-not $client.ConnectAsync($HostName, $Port).Wait([timespan]::FromSeconds($TimeoutSeconds))) {
            throw "TCP connect timed out after $TimeoutSeconds s"
        }
        $errors = [ref]'None'
        $callback = [System.Net.Security.RemoteCertificateValidationCallback] {
            param($sslSender, $certificate, $chain, $sslPolicyErrors)
            $null = $sslSender, $certificate, $chain
            $errors.Value = "$sslPolicyErrors"
            return $true   # inspect, don't enforce: an invalid certificate must still be reported
        }
        $ssl = [System.Net.Security.SslStream]::new($client.GetStream(), $false, $callback)
        try {
            $ssl.AuthenticateAsClient($HostName)
            $c = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($ssl.RemoteCertificate)
            [pscustomobject]@{
                Subject = $c.Subject; Issuer = $c.Issuer; NotAfter = $c.NotAfter; Thumbprint = $c.Thumbprint; PolicyErrors = $errors.Value
            }
        }
        finally { $ssl.Dispose() }
    }
    finally { $client.Dispose() }
}
