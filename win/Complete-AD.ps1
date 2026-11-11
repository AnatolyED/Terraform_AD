1. 
$entry = [ADSI]"LDAP://$managedDn"
$acl = $entry.ObjectSecurity
$terraformSid = (Get-ADUser 'svc-terraform').SID
$rotationSid = (Get-ADUser 'svc-rotation').SID

$allow = [System.Security.AccessControl.AccessControlType]::Allow
$deny = [System.Security.AccessControl.AccessControlType]::Deny
$all = [DirectoryServices.ActiveDirectorySecurityInheritance]::All
$descendants = [DirectoryServices.ActiveDirectorySecurityInheritance]::Descendents

$acl.AddAccessRule([DirectoryServices.ActiveDirectoryAccessRule]::new(
  $terraformSid, [DirectoryServices.ActiveDirectoryRights]::GenericAll, $allow, $all
))

$deleteRights = [DirectoryServices.ActiveDirectoryRights]'DeleteChild, DeleteTree'
$acl.AddAccessRule([DirectoryServices.ActiveDirectoryAccessRule]::new(
  $terraformSid, $deleteRights, $deny, $all
))

$resetPassword = [guid]'00299570-246d-11d0-a768-00aa006e0529'
$userClass = [guid]'bf967aba-0de6-11d0-a285-00aa003049e2'
$acl.AddAccessRule([DirectoryServices.ActiveDirectoryAccessRule]::new(
  $rotationSid, [DirectoryServices.ActiveDirectoryRights]::ExtendedRight,
  $allow, $resetPassword, $descendants, $userClass
))

$entry.ObjectSecurity = $acl
$entry.CommitChanges()
$entry.Dispose()

2.
New-Item -ItemType Directory -Path 'C:\TerraformAD' -Force | Out-Null

$cert = New-SelfSignedCertificate `
  -DnsName 'dc01.ad.example' `
  -Type SSLServerAuthentication `
  -CertStoreLocation 'Cert:\LocalMachine\My' `
  -NotAfter (Get-Date).AddDays(30)

Export-Certificate -Cert $cert -FilePath 'C:\TerraformAD\ad-ca.cer' | Out-Null

Import-Certificate `
  -FilePath 'C:\TerraformAD\ad-ca.cer' `
  -CertStoreLocation 'Cert:\LocalMachine\Root' | Out-Null

certutil -encode C:\TerraformAD\ad-ca.cer C:\TerraformAD\ad-ca.pem

3.
$debianIp = Read-Host 'IPv4-адрес Debian для доступа к LDAPS'

New-NetFirewallRule `
  -DisplayName 'TerraformAD LDAPS from Debian' `
  -Direction Inbound -Action Allow -Protocol TCP `
  -LocalPort 636 -RemoteAddress $debianIp

Restart-Computer

4.
