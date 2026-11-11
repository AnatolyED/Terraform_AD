# Ручное развёртывание · Test

Разверните отдельный контур ADM на Windows Server 2022 и двух Debian 12 VM, используя новые тестовые проект и тома.

На каждом Debian выполняйте его блоки в одном Bash-сеансе и подставьте значения в угловых скобках.

## 1. Windows AD DS

Закрепите IPv4 и имя `dc1`, затем в PowerShell от администратора создайте отдельный лес `adm.example`. [Установка AD DS](https://learn.microsoft.com/windows-server/identity/ad-ds/deploy/install-active-directory-domain-services--level-100-)

```powershell
Install-WindowsFeature AD-Domain-Services -IncludeManagementTools
Install-ADDSForest -DomainName adm.example -DomainNetbiosName ADM -InstallDns `
  -SafeModeAdministratorPassword (Read-Host 'DSRM password' -AsSecureString) -Force
```

После перезагрузки укажите собственный IPv4 контроллера в настройках DNS и создайте OU, bind-учётки и делегирование.

```powershell
Import-Module ActiveDirectory
$base = 'DC=adm,DC=example'
$managed = "OU=TerraformADM,$base"
New-ADOrganizationalUnit -Name TerraformADM -Path $base -ProtectedFromAccidentalDeletion $true
foreach ($name in 'svc-terraform','svc-auth','svc-rotation') {
  New-ADUser -Name $name -SamAccountName $name -UserPrincipalName "$name@adm.example" `
    -Path "CN=Users,$base" -Enabled $true -AccountPassword (Read-Host $name -AsSecureString)
}
$entry = [DirectoryServices.DirectoryEntry]::new("LDAP://dc1.adm.example/$managed")
$entry.Options.SecurityMasks = [DirectoryServices.SecurityMasks]::Dacl
$entry.RefreshCache([string[]]@('distinguishedName'))
$acl = $entry.ObjectSecurity
$tf = (Get-ADUser svc-terraform).SID
$rotation = (Get-ADUser svc-rotation).SID
$acl.AddAccessRule([DirectoryServices.ActiveDirectoryAccessRule]::new($tf,'GenericAll','Allow','All'))
$acl.AddAccessRule([DirectoryServices.ActiveDirectoryAccessRule]::new($tf,'DeleteChild, DeleteTree','Deny','All'))
$acl.AddAccessRule([DirectoryServices.ActiveDirectoryAccessRule]::new($rotation,'ExtendedRight','Allow',`
  [guid]'00299570-246d-11d0-a768-00aa006e0529','Descendents',[guid]'bf967aba-0de6-11d0-a285-00aa003049e2'))
$entry.ObjectSecurity = $acl
$entry.CommitChanges()
$entry.Dispose()
```

Выпустите LDAPS-сертификат, откройте TCP 636 для двух Debian VM и передайте публичный PEM на хост GitLab. [Требования к сертификату LDAPS](https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/configure-ldap-signing-certificates)

```powershell
$cert = New-SelfSignedCertificate -DnsName dc1.adm.example -Type SSLServerAuthentication `
  -CertStoreLocation Cert:\LocalMachine\My -NotAfter (Get-Date).AddDays(30)
Export-Certificate -Cert $cert -FilePath C:\ad-ca.cer
Import-Certificate -FilePath C:\ad-ca.cer -CertStoreLocation Cert:\LocalMachine\Root
$b64 = [Convert]::ToBase64String($cert.RawData,[Base64FormattingOptions]::InsertLineBreaks).Replace([string][char]13,'')
$pem = (@('-----BEGIN CERTIFICATE-----',$b64,'-----END CERTIFICATE-----') -join [char]10) + [char]10
[IO.File]::WriteAllText('C:\ad-ca.pem',$pem,[Text.Encoding]::ASCII)
New-NetFirewallRule -DisplayName 'ADM LDAPS from Debian' -Direction Inbound -Action Allow `
  -Protocol TCP -LocalPort 636 -RemoteAddress '<GITLAB_IPV4>','<VAULT_IPV4>'
Restart-Computer
```

## 2. Debian и офлайн-образы

Установите [зависимости Debian](platform.md#зависимости-debian) на обеих VM.

На обеих VM клонируйте `Test` из офлайн-комплекта.

```bash
bundle=/home/aed/terraform-ad-offline
git clone -b Test "$bundle/Terraform_AD-debian12.bundle" /home/aed/Terraform_AD
cd /home/aed/Terraform_AD
```

На хосте GitLab проверьте контрольные суммы и импортируйте образы Runner и GitLab.

```bash
(cd "$bundle" && sha256sum -c SHA256SUMS && sha256sum -c GITLAB-SHA256SUMS)
sudo docker load -i "$bundle/runner-images.tar"
sudo docker load -i "$bundle/gitlab-image.tar"
```

## 3. TLS, GitLab и Vault

На обеих VM задайте фактические адреса, обеспечьте разрешение FQDN AD, GitLab и Vault и откройте TCP 8929 к GitLab и TCP 8200 к Vault.

```bash
export ADM_RUNTIME=/home/aed/terraform-ad-runtime
export ADM_AD_HOST=dc1.adm.example ADM_AD_IP='<AD_IPV4>'
export ADM_GITLAB_HOST=gitlab.adm.example ADM_GITLAB_PORT=8929 ADM_GITLAB_BIND_IP='<GITLAB_IPV4>'
export ADM_VAULT_HOST=vault.adm.example ADM_VAULT_PORT=8200 ADM_VAULT_BIND_IP='<VAULT_IPV4>'
gitlab_url="https://$ADM_GITLAB_HOST:$ADM_GITLAB_PORT"
vault_url="https://$ADM_VAULT_HOST:$ADM_VAULT_PORT"
gitlab_ca="$ADM_RUNTIME/tls/adm-ca.pem"
vault_ca="$gitlab_ca"
ad_ca=/home/aed/ad-ca.pem
umask 077
mkdir -p "$ADM_RUNTIME/tls"
cd /home/aed/Terraform_AD
compose=(sudo --preserve-env=ADM_RUNTIME,ADM_AD_HOST,ADM_AD_IP,ADM_GITLAB_HOST,ADM_GITLAB_PORT,ADM_GITLAB_BIND_IP,ADM_VAULT_HOST,ADM_VAULT_PORT,ADM_VAULT_BIND_IP docker compose -f deploy/test/compose.yaml)
```

На хосте GitLab выпустите отдельные TLS-ключи и передайте на Vault VM только `adm-ca.pem`, `vault.pem` и `vault.key`.

```bash
tls="$ADM_RUNTIME/tls"
openssl req -x509 -newkey rsa:3072 -nodes -days 30 -subj '/CN=Terraform AD ADM CA' \
  -addext 'basicConstraints=critical,CA:TRUE' -keyout "$ADM_RUNTIME/adm-ca.key" -out "$gitlab_ca"
for service in gitlab vault; do
  host=$ADM_GITLAB_HOST
  [[ $service != vault ]] || host=$ADM_VAULT_HOST
  openssl req -new -newkey rsa:3072 -nodes -subj "/CN=$host" \
    -keyout "$tls/$service.key" -out "$ADM_RUNTIME/$service.csr"
  printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\n' "$host" > "$ADM_RUNTIME/$service.ext"
  openssl x509 -req -in "$ADM_RUNTIME/$service.csr" -CA "$gitlab_ca" -CAkey "$ADM_RUNTIME/adm-ca.key" \
    -CAcreateserial -days 30 -sha256 -extfile "$ADM_RUNTIME/$service.ext" -out "$tls/$service.pem"
done
"${compose[@]}" --profile terraform up -d --pull never gitlab
curl -fsS --retry 30 --retry-delay 5 --retry-connrefused --cacert "$gitlab_ca" \
  "$gitlab_url/.well-known/openid-configuration" | jq -er .issuer
"${compose[@]}" --profile terraform exec -T gitlab cat /etc/gitlab/initial_root_password
```

На Vault VM импортируйте образ, задайте Raft и TLS, затем инициализируйте и распечатайте хранилище. [Инициализация Vault](https://developer.hashicorp.com/vault/docs/commands/operator/init)

```bash
(cd "$bundle" && sha256sum -c VAULT-SHA256SUMS)
sudo docker load -i "$bundle/vault-image.tar"
tls="$ADM_RUNTIME/tls"
cat > "$tls/vault.hcl" <<EOF
ui = true
disable_mlock = true
api_addr = "$vault_url"
cluster_addr = "https://$ADM_VAULT_HOST:8201"
storage "raft" {
  path = "/vault/file"
  node_id = "terraform-ad-adm"
}
listener "tcp" {
  address = "0.0.0.0:8200"
  tls_cert_file = "/test-tls/vault.pem"
  tls_key_file = "/test-tls/vault.key"
}
EOF
chmod 0644 "$tls/vault.hcl" "$tls/vault.pem" "$vault_ca"
vault_image=$("${compose[@]}" --profile vault config --images | grep '/vault:')
sudo docker run --rm --user 0 --network none --entrypoint /bin/sh \
  -v "$tls:/test-tls" "$vault_image" \
  -c 'chown vault:vault /test-tls/vault.key && chmod 0600 /test-tls/vault.key'
"${compose[@]}" --profile vault up -d --pull never vault
curl -fsS --retry 10 --retry-connrefused --cacert "$vault_ca" "$vault_url/v1/sys/init" | jq -e '.initialized == false'
curl -fsS --cacert "$vault_ca" -X PUT --data '{"secret_shares":1,"secret_threshold":1}' \
  "$vault_url/v1/sys/init" > "$ADM_RUNTIME/vault-init.json"
jq -c '{key:.keys_base64[0]}' "$ADM_RUNTIME/vault-init.json" |
  curl -fsS --cacert "$vault_ca" -X PUT --data-binary @- "$vault_url/v1/sys/unseal" |
  jq -e '.sealed == false'
```

## 4. GitLab-проект и Runner

В локальном GitLab создайте закрытый проект `terraform-ad-adm` без README, импортируйте `Test` как ветку по умолчанию и защитите её.

```bash
project_id='<LOCAL_GITLAB_PROJECT_ID>'
branch=Test
vault_id=vault-01
vault_namespace=''
sed -i "s|^  address: .*|  address: $vault_url|" data/vault/clusters.yaml
git add -- data/vault/clusters.yaml
if ! git diff --cached --quiet; then git commit -m 'Set the ADM Vault address'; fi
git remote add adm "$gitlab_url/root/terraform-ad-adm.git"
git -c http.sslCAInfo="$gitlab_ca" push -o ci.skip adm HEAD:refs/heads/Test
```

Задайте параметры сети и выполните [регистрацию Runner](platform.md#регистрация-runner).

```bash
runner_network=terraform-ad-debian12-adm
runner_hosts=(--docker-extra-hosts "$ADM_AD_HOST:$ADM_AD_IP" --docker-extra-hosts "$ADM_VAULT_HOST:$ADM_VAULT_BIND_IP")
```

## 5. GitLab-переменные и Vault JWT

Задайте защищённые переменные в **Settings → CI/CD → Variables**, храните пароли как Masked/Hidden и сертификаты как File.

| Scope | Переменные |
|---|---|
| `*` | `AD_DEPLOY_ENABLED=true`, `AD_DEPLOY_ENVIRONMENT=adm`, `VAULT_DEPLOY_MODE=single`, `VAULT_TARGET_ID=vault-01` |
| `ad/adm` | `AD_USERNAME=svc-terraform@adm.example`, `AD_PASSWORD`, `AD_TLS_CA_CERT_FILE=ad-ca.pem`, `TF_VAR_ad_ldap_url=ldaps://dc1.adm.example:636`, `TF_VAR_ad_managed_base_dn=OU=TerraformADM,DC=adm,DC=example`, `TF_VAR_ad_user_passwords` |
| `vault/vault-01` | `VAULT_CACERT=adm-ca.pem`, `TF_VAR_vault_ldap_ca_file=ad-ca.pem`, `TF_VAR_vault_ldap_url=ldaps://dc1.adm.example:636`, `TF_VAR_vault_ldap_auth_bind_dn=CN=svc-auth,CN=Users,DC=adm,DC=example`, `TF_VAR_vault_ldap_auth_bind_password` |
| `vault/vault-01` | `TF_VAR_vault_ldap_auth_user_dn=OU=Identity,OU=TerraformADM,DC=adm,DC=example`, `TF_VAR_vault_ldap_auth_group_dn=OU=Groups,OU=Identity,OU=TerraformADM,DC=adm,DC=example`, `TF_VAR_vault_ldap_secrets_bind_dn=CN=svc-rotation,CN=Users,DC=adm,DC=example`, `TF_VAR_vault_ldap_secrets_bind_password`, `TF_VAR_vault_ldap_secrets_user_dn=OU=Services,OU=Identity,OU=TerraformADM,DC=adm,DC=example` |

Сгенерируйте JSON-карту начальных паролей в локальный файл с ограниченными правами и вставьте её в `TF_VAR_ad_user_passwords`.

```bash
umask 077
jq -nc --arg reader "T1a!$(openssl rand -hex 18)" --arg outsider "T2a!$(openssl rand -hex 18)" \
  --arg app "T3a!$(openssl rand -hex 18)" '{"adm-reader":$reader,"adm-outsider":$outsider,"adm-app":$app}' \
  > "$ADM_RUNTIME/test-passwords.json"
```

На хосте GitLab выполните [настройку JWT](platform.md#jwt-для-vault), введя начальный токен из защищённого файла Vault.

## 6. Применение и проверка

В **Build → Pipelines → New pipeline** выберите `Test`, проверьте планы без удалений и вручную запустите `ad:apply`, затем `vault:apply: [vault-01]`.

Проверьте LDAP-доступ читателя, отказ постороннему пользователю и успешный LDAPS-вход с ротированным паролем.

```bash
login() {
  jq -ce --arg user "$1" '{password:.[$user]}' "$ADM_RUNTIME/test-passwords.json" |
    curl -fsS --cacert "$vault_ca" -H "Content-Type: application/json" --data-binary @- "$vault_url/v1/auth/ad-ldap/login/$1" |
    jq -er .auth.client_token
}
reader=$(login adm-reader)
outsider=$(login adm-outsider)
secret_url="$vault_url/v1/ad-creds/static-cred/adm-app"
test "$(curl -sS --cacert "$vault_ca" -o /dev/null -w '%{http_code}' -H @<(printf 'X-Vault-Token: %s\n' "$outsider") "$secret_url")" = 403
secret() {
  curl -fsS --cacert "$vault_ca" -H @<(printf 'X-Vault-Token: %s\n' "$reader") "$secret_url" | jq -er .data.password
}
before=$(secret)
sleep 65
after=$(secret)
test "$before" != "$after"
printf '%s' "$after" | LDAPTLS_CACERT="$ad_ca" ldapwhoami -x -H "ldaps://$ADM_AD_HOST:636" -D adm-app@adm.example -y /dev/stdin
unset reader outsider before after
```

В GitLab проверьте отдельные state `ad-adm` и `vault-vault-01`, затем запустите новый pipeline и убедитесь, что оба плана показывают `No changes`.
