param(
  [Parameter(Mandatory)]
  [ValidateSet('Forest','Directory')]
  [string]$Phase,
  [string]$OutputDirectory = 'C:\TerraformLab'
)

$ErrorActionPreference = 'Stop'
$labDomain = 'lab.example'
$baseDn = 'DC=lab,DC=example'
$managedDn = "OU=TerraformLab,$baseDn"

if ($Phase -eq 'Forest') {
  if ((Get-CimInstance Win32_ComputerSystem).PartOfDomain) {
    throw 'Run Forest on a dedicated Windows Server VM before it joins a domain.'
  }
  Install-WindowsFeature AD-Domain-Services -IncludeManagementTools | Out-Null
  $dsrm = Read-Host 'Directory Services Restore Mode password' -AsSecureString
  Install-ADDSForest -DomainName $labDomain -DomainNetbiosName LAB -InstallDns -SafeModeAdministratorPassword $dsrm -Force
  exit
}

Import-Module ActiveDirectory
if ((Get-ADDomain).DNSRoot -ne $labDomain) {
  throw "Directory phase is limited to $labDomain."
}
if (!(Get-ADOrganizationalUnit -LDAPFilter '(ou=TerraformLab)' -SearchBase $baseDn -SearchScope OneLevel)) {
  New-ADOrganizationalUnit -Name TerraformLab -Path $baseDn -ProtectedFromAccidentalDeletion $true
}
foreach ($name in @('svc-terraform','svc-auth','svc-rotation')) {
  if (!(Get-ADUser -LDAPFilter "(sAMAccountName=$name)")) {
    $password = Read-Host "Password for $name" -AsSecureString
    $user = @{Name=$name;SamAccountName=$name;UserPrincipalName="$name@$labDomain";Path="CN=Users,$baseDn";AccountPassword=$password;Enabled=$true}
    New-ADUser @user
  }
}

$directory = [ADSI]"LDAP://$managedDn"
$acl = $directory.ObjectSecurity
$terraformSid = (Get-ADUser 'svc-terraform').SID
$rotationSid = (Get-ADUser 'svc-rotation').SID
$allow = [System.Security.AccessControl.AccessControlType]::Allow
$deny = [System.Security.AccessControl.AccessControlType]::Deny
$all = [DirectoryServices.ActiveDirectorySecurityInheritance]::All
$descendants = [DirectoryServices.ActiveDirectorySecurityInheritance]::Descendents
$rights = [DirectoryServices.ActiveDirectoryRights]'DeleteChild, DeleteTree'
$acl.AddAccessRule([DirectoryServices.ActiveDirectoryAccessRule]::new($terraformSid, [DirectoryServices.ActiveDirectoryRights]::GenericAll, $allow, $all))
$acl.AddAccessRule([DirectoryServices.ActiveDirectoryAccessRule]::new($terraformSid, $rights, $deny, $all))
$resetPassword = [guid]'00299570-246d-11d0-a768-00aa006e0529'
$userClass = [guid]'bf967aba-0de6-11d0-a285-00aa003049e2'
$acl.AddAccessRule([DirectoryServices.ActiveDirectoryAccessRule]::new($rotationSid, [DirectoryServices.ActiveDirectoryRights]::ExtendedRight, $allow, $resetPassword, $descendants, $userClass))
$directory.ObjectSecurity = $acl
$directory.CommitChanges()
$directory.Dispose()

$fqdn = "$env:COMPUTERNAME.$labDomain".ToLowerInvariant()
$subject = "CN=$fqdn"
$certificate = Get-ChildItem Cert:\LocalMachine\My |
  Where-Object { $_.Subject -eq $subject -and $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date) } |
  Sort-Object NotAfter -Descending | Select-Object -First 1
if (!$certificate) {
  $certificateParameters = @{DnsName=$fqdn;Type='SSLServerAuthentication';CertStoreLocation='Cert:\LocalMachine\My';NotAfter=(Get-Date).AddDays(30)}
  $certificate = New-SelfSignedCertificate @certificateParameters
}
$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
$der = Join-Path $OutputDirectory 'ad-ca.cer'
$pem = Join-Path $OutputDirectory 'ad-ca.pem'
Export-Certificate -Cert $certificate -FilePath $der -Force | Out-Null
Import-Certificate -FilePath $der -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
@('-----BEGIN CERTIFICATE-----',[Convert]::ToBase64String($certificate.RawData,[Base64FormattingOptions]::InsertLineBreaks),'-----END CERTIFICATE-----') |
  Set-Content -LiteralPath $pem -Encoding Ascii
Write-Output "LDAPS host: $fqdn"
Write-Output "Managed base: $managedDn"
Write-Output "Copy the public certificate $pem to Debian. Reboot this VM, then check TCP 636."
