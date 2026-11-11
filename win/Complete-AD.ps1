#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
Completes AD configuration for the ad.example Terraform lab.

.DESCRIPTION
Run on the domain controller after creating OU=TerraformAD and the enabled
svc-terraform, svc-auth and svc-rotation accounts. Configures OU delegation,
a lab LDAPS certificate and an inbound firewall rule for the Debian host.
The script exports the public certificate and leaves the reboot to the operator.

.PARAMETER DebianIp
The source IPv4 address that the Windows firewall sees for Debian LDAPS traffic.

.PARAMETER OutputDirectory
Directory where the public LDAPS certificate is exported.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [ValidateScript({
    $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and
    $_.IPAddressToString -notin @('0.0.0.0', '255.255.255.255') -and
    -not [System.Net.IPAddress]::IsLoopback($_)
  })]
  [System.Net.IPAddress]$DebianIp,

  [string]$OutputDirectory = 'C:\TerraformAD'
)

$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory

$domain = Get-ADDomain -Server $env:COMPUTERNAME
if ($domain.DNSRoot -ne 'ad.example') {
  throw "This lab script requires ad.example. Found $($domain.DNSRoot)."
}

$controller = Get-ADDomainController -Identity $env:COMPUTERNAME -Server $env:COMPUTERNAME
$fqdn = $controller.HostName.ToLowerInvariant()
$managedDn = "OU=TerraformAD,$($domain.DistinguishedName)"
$managedOu = Get-ADOrganizationalUnit -Identity $managedDn -Server $fqdn -Properties ProtectedFromAccidentalDeletion

$accounts = @{}
foreach ($name in 'svc-terraform', 'svc-auth', 'svc-rotation') {
  $account = Get-ADUser -Identity $name -Server $fqdn
  if (!$account.Enabled) {
    throw "Enable $name before running this script."
  }
  $accounts[$name] = $account
}

if (!$managedOu.ProtectedFromAccidentalDeletion) {
  Set-ADOrganizationalUnit -Identity $managedDn -Server $fqdn -ProtectedFromAccidentalDeletion $true
}

# Open the OU returned by AD, rather than relying on variables from the caller.
$ldapPath = 'LDAP://{0}/{1}' -f $fqdn, $managedOu.DistinguishedName
$entry = [System.DirectoryServices.DirectoryEntry]::new($ldapPath)
try {
  try {
    $entry.Options.SecurityMasks = [System.DirectoryServices.SecurityMasks]::Dacl
    $entry.RefreshCache([string[]]@('distinguishedName'))
    $acl = $entry.ObjectSecurity
  }
  catch {
    throw "Cannot read the OU ACL at $ldapPath. $($_.Exception.Message)"
  }
  if ($null -eq $acl) {
    throw "AD returned an empty OU ACL at $ldapPath."
  }

  $allow = [System.Security.AccessControl.AccessControlType]::Allow
  $deny = [System.Security.AccessControl.AccessControlType]::Deny
  $all = [System.DirectoryServices.ActiveDirectorySecurityInheritance]::All
  $descendants = [System.DirectoryServices.ActiveDirectorySecurityInheritance]::Descendents
  $deleteRights = [System.DirectoryServices.ActiveDirectoryRights]'DeleteChild, DeleteTree'
  $resetPassword = [guid]'00299570-246d-11d0-a768-00aa006e0529'
  $userClass = [guid]'bf967aba-0de6-11d0-a285-00aa003049e2'

  $rules = @(
    [System.DirectoryServices.ActiveDirectoryAccessRule]::new(
      $accounts['svc-terraform'].SID, [System.DirectoryServices.ActiveDirectoryRights]::GenericAll, $allow, $all
    )
    [System.DirectoryServices.ActiveDirectoryAccessRule]::new(
      $accounts['svc-terraform'].SID, $deleteRights, $deny, $all
    )
    [System.DirectoryServices.ActiveDirectoryAccessRule]::new(
      $accounts['svc-rotation'].SID, [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight,
      $allow, $resetPassword, $descendants, $userClass
    )
  )

  $explicitRules = $acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier])
  $changed = $false
  foreach ($rule in $rules) {
    $existingRule = $explicitRules | Where-Object {
      $_.IdentityReference -eq $rule.IdentityReference -and
      $_.AccessControlType -eq $rule.AccessControlType -and
      $_.InheritanceType -eq $rule.InheritanceType -and
      $_.ObjectType -eq $rule.ObjectType -and
      $_.InheritedObjectType -eq $rule.InheritedObjectType -and
      ($_.ActiveDirectoryRights -band $rule.ActiveDirectoryRights) -eq $rule.ActiveDirectoryRights
    } | Select-Object -First 1

    if (!$existingRule) {
      $acl.AddAccessRule($rule)
      $changed = $true
    }
  }

  if ($changed) {
    $entry.ObjectSecurity = $acl
    $entry.CommitChanges()
  }
}
finally {
  $entry.Dispose()
}

$now = Get-Date
$certificate = Get-ChildItem -Path Cert:\LocalMachine\My -SSLServerAuthentication |
  Where-Object {
    $_.HasPrivateKey -and
    $_.Subject -eq "CN=$fqdn" -and
    $_.Issuer -eq $_.Subject -and
    $_.DnsNameList.Unicode -contains $fqdn -and
    $_.NotBefore -le $now -and
    $_.NotAfter -gt $now
  } |
  Sort-Object NotAfter -Descending |
  Select-Object -First 1

if (!$certificate) {
  $certificate = New-SelfSignedCertificate -DnsName $fqdn -Type SSLServerAuthentication `
    -CertStoreLocation 'Cert:\LocalMachine\My' -NotAfter $now.AddDays(30)
}

$directory = New-Item -ItemType Directory -Path $OutputDirectory -Force
$cerPath = Join-Path $directory.FullName 'ad-ca.cer'
$pemPath = Join-Path $directory.FullName 'ad-ca.pem'
Export-Certificate -Cert $certificate -FilePath $cerPath -Force | Out-Null

$rootPath = "Cert:\LocalMachine\Root\$($certificate.Thumbprint)"
if (!(Test-Path -LiteralPath $rootPath)) {
  Import-Certificate -FilePath $cerPath -CertStoreLocation 'Cert:\LocalMachine\Root' | Out-Null
}

$base64 = [Convert]::ToBase64String(
  $certificate.RawData, [Base64FormattingOptions]::InsertLineBreaks
).Replace("`r", '')
$pem = "-----BEGIN CERTIFICATE-----`n$base64`n-----END CERTIFICATE-----`n"
[System.IO.File]::WriteAllText($pemPath, $pem, [System.Text.Encoding]::ASCII)

$firewallRule = @{
  Name = 'TerraformAD-Lab-LDAPS'
  Direction = 'Inbound'
  Action = 'Allow'
  Enabled = 'True'
  Protocol = 'TCP'
  LocalPort = 636
  RemoteAddress = $DebianIp.IPAddressToString
}

if (Get-NetFirewallRule -Name $firewallRule.Name -ErrorAction SilentlyContinue) {
  Set-NetFirewallRule @firewallRule
} else {
  New-NetFirewallRule @firewallRule -DisplayName 'TerraformAD lab LDAPS from Debian' | Out-Null
}

Write-Output "Managed OU: $managedDn"
Write-Output "LDAPS URL: ldaps://${fqdn}:636"
Write-Output "Allowed Debian source: $DebianIp"
Write-Output "Public certificate: $pemPath"
Write-Output "Certificate thumbprint: $($certificate.Thumbprint)"
Write-Output 'Copy the PEM to Debian, restart the domain controller, and verify LDAPS from Debian.'
