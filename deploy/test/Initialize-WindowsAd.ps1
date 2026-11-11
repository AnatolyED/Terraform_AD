[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [ValidateSet('Forest','Directory')]
  [string]$Phase,
  [ValidatePattern('^[a-zA-Z0-9-]+\.(example|test)$')]
  [string]$LabDomain = 'lab.example',
  [ValidatePattern('^[a-zA-Z][a-zA-Z0-9-]*$')]
  [string]$ManagedOu = 'TerraformLab',
  [System.Net.IPAddress[]]$DebianIp,
  [string]$OutputDirectory = 'C:\TerraformAD',
  [switch]$Check
)

$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'Run PowerShell as Administrator.'
}
$computer = Get-CimInstance Win32_ComputerSystem
if ($computer.PartOfDomain -and $computer.Domain -ne $LabDomain) {
  throw 'This script requires a dedicated test domain.'
}
if ($Phase -eq 'Forest') {
  if ($computer.PartOfDomain) { Write-Output "Domain already configured: $LabDomain"; return }
  if ($Check) { Get-WindowsFeature AD-Domain-Services | Select-Object Name,InstallState; return }
  Install-WindowsFeature AD-Domain-Services -IncludeManagementTools | Out-Null
  $dsrm = Read-Host 'Directory Services Restore Mode password' -AsSecureString
  Install-ADDSForest -DomainName $LabDomain -InstallDns -SafeModeAdministratorPassword $dsrm -Force
  return
}

if (!$computer.PartOfDomain -or !$DebianIp -or ($DebianIp | Where-Object {
  $_.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
  $_.IPAddressToString -in @('0.0.0.0','255.255.255.255') -or [Net.IPAddress]::IsLoopback($_)
})) {
  throw 'Directory requires the test domain and the source IPv4 addresses of both Debian hosts.'
}
Import-Module ActiveDirectory
$domain = Get-ADDomain -Server $env:COMPUTERNAME
$controller = Get-ADDomainController -Identity $env:COMPUTERNAME -Server $env:COMPUTERNAME
$fqdn = $controller.HostName.ToLowerInvariant()
$managedDn = "OU=$ManagedOu,$($domain.DistinguishedName)"
if ($Check) {
  Write-Output "LDAPS host: $fqdn"
  Write-Output "Managed OU: $managedDn"
  return
}
$managed = Get-ADOrganizationalUnit -LDAPFilter "(ou=$ManagedOu)" -SearchBase $domain.DistinguishedName -SearchScope OneLevel -Server $fqdn -Properties ProtectedFromAccidentalDeletion
if (!$managed) {
  $managed = New-ADOrganizationalUnit -Name $ManagedOu -Path $domain.DistinguishedName -ProtectedFromAccidentalDeletion $true -Server $fqdn -PassThru
} elseif (!$managed.ProtectedFromAccidentalDeletion) {
  Set-ADOrganizationalUnit -Identity $managed -ProtectedFromAccidentalDeletion $true -Server $fqdn
}

$accounts = @{}
foreach ($name in 'svc-terraform','svc-auth','svc-rotation') {
  $account = Get-ADUser -LDAPFilter "(sAMAccountName=$name)" -Server $fqdn
  if (!$account) {
    $password = Read-Host "Password for $name" -AsSecureString
    $account = New-ADUser -Name $name -SamAccountName $name -UserPrincipalName "$name@$LabDomain" `
      -Path $domain.UsersContainer -AccountPassword $password -Enabled $true -Server $fqdn -PassThru
  }
  if (!$account.Enabled) { throw "Account is disabled: $name" }
  $accounts[$name] = $account
}

$entry = [DirectoryServices.DirectoryEntry]::new(('LDAP://{0}/{1}' -f $fqdn,$managed.DistinguishedName))
try {
  $entry.Options.SecurityMasks = [DirectoryServices.SecurityMasks]::Dacl
  $entry.RefreshCache([string[]]@('distinguishedName'))
  $acl = $entry.ObjectSecurity
  $allow = [Security.AccessControl.AccessControlType]::Allow
  $deny = [Security.AccessControl.AccessControlType]::Deny
  $all = [DirectoryServices.ActiveDirectorySecurityInheritance]::All
  $descendants = [DirectoryServices.ActiveDirectorySecurityInheritance]::Descendents
  $deleteRights = [DirectoryServices.ActiveDirectoryRights]'DeleteChild, DeleteTree'
  $resetPassword = [guid]'00299570-246d-11d0-a768-00aa006e0529'
  $userClass = [guid]'bf967aba-0de6-11d0-a285-00aa003049e2'
  $rules = @(
    [DirectoryServices.ActiveDirectoryAccessRule]::new($accounts['svc-terraform'].SID,[DirectoryServices.ActiveDirectoryRights]::GenericAll,$allow,$all)
    [DirectoryServices.ActiveDirectoryAccessRule]::new($accounts['svc-terraform'].SID,$deleteRights,$deny,$all)
    [DirectoryServices.ActiveDirectoryAccessRule]::new($accounts['svc-rotation'].SID,[DirectoryServices.ActiveDirectoryRights]::ExtendedRight,$allow,$resetPassword,$descendants,$userClass)
  )
  $explicit = $acl.GetAccessRules($true,$false,[Security.Principal.SecurityIdentifier])
  $changed = $false
  foreach ($rule in $rules) {
    if (!($explicit | Where-Object {
      $_.IdentityReference -eq $rule.IdentityReference -and $_.AccessControlType -eq $rule.AccessControlType -and
      $_.InheritanceType -eq $rule.InheritanceType -and $_.ObjectType -eq $rule.ObjectType -and
      $_.InheritedObjectType -eq $rule.InheritedObjectType -and
      ($_.ActiveDirectoryRights -band $rule.ActiveDirectoryRights) -eq $rule.ActiveDirectoryRights
    })) {
      $acl.AddAccessRule($rule)
      $changed = $true
    }
  }
  if ($changed) { $entry.ObjectSecurity = $acl; $entry.CommitChanges() }
} finally { $entry.Dispose() }

$now = Get-Date
$certificate = Get-ChildItem -Path Cert:\LocalMachine\My -SSLServerAuthentication |
  Where-Object { $_.HasPrivateKey -and $_.Subject -eq "CN=$fqdn" -and $_.Issuer -eq $_.Subject -and
    $_.DnsNameList.Unicode -contains $fqdn -and $_.NotBefore -le $now -and $_.NotAfter -gt $now } |
  Sort-Object NotAfter -Descending | Select-Object -First 1
if (!$certificate) {
  $certificate = New-SelfSignedCertificate -DnsName $fqdn -Type SSLServerAuthentication `
    -CertStoreLocation 'Cert:\LocalMachine\My' -NotAfter $now.AddDays(30)
}
$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
$cer = Join-Path $OutputDirectory 'ad-ca.cer'
$pem = Join-Path $OutputDirectory 'ad-ca.pem'
Export-Certificate -Cert $certificate -FilePath $cer -Force | Out-Null
if (!(Test-Path -LiteralPath "Cert:\LocalMachine\Root\$($certificate.Thumbprint)")) {
  Import-Certificate -FilePath $cer -CertStoreLocation 'Cert:\LocalMachine\Root' | Out-Null
}
$base64 = [Convert]::ToBase64String($certificate.RawData,[Base64FormattingOptions]::InsertLineBreaks).Replace("`r",'')
[IO.File]::WriteAllText($pem,"-----BEGIN CERTIFICATE-----`n$base64`n-----END CERTIFICATE-----`n",[Text.Encoding]::ASCII)
$firewall = @{Name='TerraformAD-Test-LDAPS';Direction='Inbound';Action='Allow';Enabled='True';Protocol='TCP';LocalPort=636;RemoteAddress=@($DebianIp | ForEach-Object IPAddressToString)}
if (Get-NetFirewallRule -Name $firewall.Name -ErrorAction SilentlyContinue) {
  Set-NetFirewallRule @firewall
} else {
  New-NetFirewallRule @firewall -DisplayName 'Terraform AD test LDAPS from Debian' | Out-Null
}
Write-Output "Managed OU: $managedDn"
Write-Output "LDAPS host: $fqdn"
Write-Output "Public certificate: $pem"
Write-Output 'Restart the domain controller before checking LDAPS.'
