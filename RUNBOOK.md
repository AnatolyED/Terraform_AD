# Ручное развёртывание · Test

Стенд использует Windows Server 2022 для AD DS, Debian 12 для GitLab и Runner и вторую Debian 12 для одного Vault.

На каждом Debian выполняйте его блоки в одном Bash-сеансе и подставьте значения в угловых скобках.

## 1. Windows AD DS

Закрепите IPv4 и имя `dc1`, затем в PowerShell от администратора создайте отдельный лес `lab.example`. [Установка AD DS](https://learn.microsoft.com/windows-server/identity/ad-ds/deploy/install-active-directory-domain-services--level-100-)

```powershell
Install-WindowsFeature AD-Domain-Services -IncludeManagementTools
Install-ADDSForest -DomainName lab.example -DomainNetbiosName LAB -InstallDns `
  -SafeModeAdministratorPassword (Read-Host 'DSRM password' -AsSecureString) -Force
```

После перезагрузки укажите собственный IPv4 контроллера в настройках DNS и создайте OU, bind-учётки и делегирование.

```powershell
Import-Module ActiveDirectory
$base = 'DC=lab,DC=example'
$managed = "OU=TerraformLab,$base"
New-ADOrganizationalUnit -Name TerraformLab -Path $base -ProtectedFromAccidentalDeletion $true
foreach ($name in 'svc-terraform','svc-auth','svc-rotation') {
  New-ADUser -Name $name -SamAccountName $name -UserPrincipalName "$name@lab.example" `
    -Path "CN=Users,$base" -Enabled $true -AccountPassword (Read-Host $name -AsSecureString)
}
$entry = [DirectoryServices.DirectoryEntry]::new("LDAP://dc1.lab.example/$managed")
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
$cert = New-SelfSignedCertificate -DnsName dc1.lab.example -Type SSLServerAuthentication `
  -CertStoreLocation Cert:\LocalMachine\My -NotAfter (Get-Date).AddDays(30)
Export-Certificate -Cert $cert -FilePath C:\ad-ca.cer
Import-Certificate -FilePath C:\ad-ca.cer -CertStoreLocation Cert:\LocalMachine\Root
$b64 = [Convert]::ToBase64String($cert.RawData,[Base64FormattingOptions]::InsertLineBreaks).Replace([string][char]13,'')
$pem = (@('-----BEGIN CERTIFICATE-----',$b64,'-----END CERTIFICATE-----') -join [char]10) + [char]10
[IO.File]::WriteAllText('C:\ad-ca.pem',$pem,[Text.Encoding]::ASCII)
New-NetFirewallRule -DisplayName 'Lab LDAPS from Debian' -Direction Inbound -Action Allow `
  -Protocol TCP -LocalPort 636 -RemoteAddress '<GITLAB_IPV4>','<VAULT_IPV4>'
Restart-Computer
```

## 2. Debian и офлайн-образы

На чистой Debian установите зависимости и Docker из зеркала, а на полностью офлайн-хосте установите те же пакеты и зависимости через `sudo apt install /path/to/debs/*.deb`. [Docker Engine для Debian](https://docs.docker.com/engine/install/debian/)

```bash
sudo apt update
sudo apt install -y ca-certificates curl git jq openssl ldap-utils
sudo install -m 0755 -d /etc/apt/keyrings
mirror=https://mirror.yandex.ru/mirrors/download.docker.com/linux/debian
sudo curl -fsSL "$mirror/gpg" -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
printf 'deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] %s bookworm stable\n' "$mirror" |
  sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo systemctl enable --now docker
sudo docker compose version
```

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
export LAB_RUNTIME=/home/aed/terraform-ad-runtime
export LAB_AD_HOST=dc1.lab.example LAB_AD_IP='<AD_IPV4>'
export LAB_GITLAB_HOST=gitlab.terraform.test LAB_GITLAB_PORT=8929 LAB_GITLAB_BIND_IP='<GITLAB_IPV4>'
export LAB_VAULT_HOST=vault.terraform.test LAB_VAULT_PORT=8200 LAB_VAULT_BIND_IP='<VAULT_IPV4>'
gitlab_url="https://$LAB_GITLAB_HOST:$LAB_GITLAB_PORT"
vault_url="https://$LAB_VAULT_HOST:$LAB_VAULT_PORT"
gitlab_ca="$LAB_RUNTIME/tls/lab-ca.pem"
vault_ca="$gitlab_ca"
ad_ca=/home/aed/ad-ca.pem
umask 077
mkdir -p "$LAB_RUNTIME/tls"
cd /home/aed/Terraform_AD
compose=(sudo --preserve-env=LAB_RUNTIME,LAB_AD_HOST,LAB_AD_IP,LAB_GITLAB_HOST,LAB_GITLAB_PORT,LAB_GITLAB_BIND_IP,LAB_VAULT_HOST,LAB_VAULT_PORT,LAB_VAULT_BIND_IP docker compose -f deploy/test/compose.yaml)
```

На хосте GitLab выпустите отдельные TLS-ключи и передайте на Vault VM только `lab-ca.pem`, `vault.pem` и `vault.key`.

```bash
tls="$LAB_RUNTIME/tls"
openssl req -x509 -newkey rsa:3072 -nodes -days 30 -subj '/CN=Terraform AD Lab CA' \
  -addext 'basicConstraints=critical,CA:TRUE' -keyout "$LAB_RUNTIME/lab-ca.key" -out "$gitlab_ca"
for service in gitlab vault; do
  host=$LAB_GITLAB_HOST
  [[ $service != vault ]] || host=$LAB_VAULT_HOST
  openssl req -new -newkey rsa:3072 -nodes -subj "/CN=$host" \
    -keyout "$tls/$service.key" -out "$LAB_RUNTIME/$service.csr"
  printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\n' "$host" > "$LAB_RUNTIME/$service.ext"
  openssl x509 -req -in "$LAB_RUNTIME/$service.csr" -CA "$gitlab_ca" -CAkey "$LAB_RUNTIME/lab-ca.key" \
    -CAcreateserial -days 30 -sha256 -extfile "$LAB_RUNTIME/$service.ext" -out "$tls/$service.pem"
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
tls="$LAB_RUNTIME/tls"
cat > "$tls/vault.hcl" <<EOF
ui = true
disable_mlock = true
api_addr = "$vault_url"
cluster_addr = "https://$LAB_VAULT_HOST:8201"
storage "raft" {
  path = "/vault/file"
  node_id = "terraform-ad-test"
}
listener "tcp" {
  address = "0.0.0.0:8200"
  tls_cert_file = "/lab-tls/vault.pem"
  tls_key_file = "/lab-tls/vault.key"
}
EOF
chmod 0644 "$tls/vault.hcl" "$tls/vault.pem" "$vault_ca"
sudo docker run --rm --user 0 --network none --entrypoint /bin/sh \
  -v "$tls:/lab-tls" terraform-ad-lab/vault:2.2.1 \
  -c 'chown vault:vault /lab-tls/vault.key && chmod 0600 /lab-tls/vault.key'
"${compose[@]}" --profile vault up -d --pull never vault
curl -fsS --retry 10 --retry-connrefused --cacert "$vault_ca" "$vault_url/v1/sys/init" | jq -e '.initialized == false'
curl -fsS --cacert "$vault_ca" -X PUT --data '{"secret_shares":1,"secret_threshold":1}' \
  "$vault_url/v1/sys/init" > "$LAB_RUNTIME/vault-init.json"
jq -c '{key:.keys_base64[0]}' "$LAB_RUNTIME/vault-init.json" |
  curl -fsS --cacert "$vault_ca" -X PUT --data-binary @- "$vault_url/v1/sys/unseal" |
  jq -e '.sealed == false'
```

## 4. GitLab-проект и Runner

В локальном GitLab создайте закрытый проект `terraform-ad-test` без README, импортируйте `Test` как ветку по умолчанию и защитите её.

```bash
project_id='<LOCAL_GITLAB_PROJECT_ID>'
branch=Test
vault_id=vault-01
vault_namespace=''
sed -i "s|^  address: .*|  address: $vault_url|" inventory/vault/clusters.yaml
git add -- inventory/vault/clusters.yaml
if ! git diff --cached --quiet; then git commit -m 'Set the lab Vault address'; fi
git remote add lab "$gitlab_url/root/terraform-ad-test.git"
git -c http.sslCAInfo="$gitlab_ca" push -o ci.skip lab HEAD:refs/heads/Test
```

В **Settings → CI/CD → Runners** создайте два проектных Runner с тегами `terraform-docker` и `terraform-deploy`, выключите задания без тегов и защитите Runner с тегом `terraform-deploy`. [Регистрация Runner](https://docs.gitlab.com/runner/register/)

```bash
runner_network=terraform-ad-debian12-test
runner_hosts=(--docker-extra-hosts "$LAB_AD_HOST:$LAB_AD_IP" --docker-extra-hosts "$LAB_VAULT_HOST:$LAB_VAULT_BIND_IP")
for kind in validate deploy; do
  name="terraform-ad-$project_id-$kind"
  config="/srv/gitlab-runner/$name"
  sudo install -m 0700 -d "$config"
  read -rsp "Runner token ($kind): " CI_SERVER_TOKEN
  printf '\n'
  export CI_SERVER_TOKEN
  sudo --preserve-env=CI_SERVER_TOKEN docker run --rm --network "$runner_network" \
    -e CI_SERVER_TOKEN -v "$config:/etc/gitlab-runner" -v "$gitlab_ca:/gitlab-ca.pem:ro" \
    terraform-ad/runner:19.5.1 register --non-interactive --url "$gitlab_url" \
    --name "$name" --executor docker --tls-ca-file /gitlab-ca.pem \
    --docker-image terraform-ad/terraform:1.17.1 --docker-helper-image terraform-ad/runner-helper:19.5.1 \
    --docker-pull-policy never --docker-network-mode "$runner_network" \
    --docker-volumes "$bundle/provider-mirror:/providers:ro" "${runner_hosts[@]}"
  unset CI_SERVER_TOKEN
  sudo docker run -d --name "$name" --restart unless-stopped --network "$runner_network" \
    -v "$config:/etc/gitlab-runner" -v "$gitlab_ca:/gitlab-ca.pem:ro" \
    -v /var/run/docker.sock:/var/run/docker.sock terraform-ad/runner:19.5.1
  sudo docker exec "$name" gitlab-runner verify
done
```

## 5. GitLab-переменные и Vault JWT

Задайте защищённые переменные в **Settings → CI/CD → Variables**, храните пароли как Masked/Hidden и сертификаты как File.

| Scope | Переменные |
|---|---|
| `*` | `AD_DEPLOY_ENABLED=true`, `AD_DEPLOY_ENVIRONMENT=lab`, `VAULT_DEPLOY_MODE=single`, `VAULT_TARGET_ID=vault-01` |
| `ad/lab` | `AD_USERNAME=svc-terraform@lab.example`, `AD_PASSWORD`, `AD_TLS_CA_CERT_FILE=ad-ca.pem`, `TF_VAR_ad_ldap_url=ldaps://dc1.lab.example:636`, `TF_VAR_ad_managed_base_dn=OU=TerraformLab,DC=lab,DC=example`, `TF_VAR_ad_user_passwords` |
| `vault/vault-01` | `VAULT_CACERT=lab-ca.pem`, `TF_VAR_vault_ldap_ca_file=ad-ca.pem`, `TF_VAR_vault_ldap_url=ldaps://dc1.lab.example:636`, `TF_VAR_vault_ldap_auth_bind_dn=CN=svc-auth,CN=Users,DC=lab,DC=example`, `TF_VAR_vault_ldap_auth_bind_password` |
| `vault/vault-01` | `TF_VAR_vault_ldap_auth_user_dn=OU=Identity,OU=TerraformLab,DC=lab,DC=example`, `TF_VAR_vault_ldap_auth_group_dn=OU=Groups,OU=Identity,OU=TerraformLab,DC=lab,DC=example`, `TF_VAR_vault_ldap_secrets_bind_dn=CN=svc-rotation,CN=Users,DC=lab,DC=example`, `TF_VAR_vault_ldap_secrets_bind_password`, `TF_VAR_vault_ldap_secrets_user_dn=OU=Services,OU=Identity,OU=TerraformLab,DC=lab,DC=example` |

Сгенерируйте JSON-карту начальных паролей в локальный файл с ограниченными правами и вставьте её в `TF_VAR_ad_user_passwords`.

```bash
umask 077
jq -nc --arg reader "T1a!$(openssl rand -hex 18)" --arg outsider "T2a!$(openssl rand -hex 18)" \
  --arg app "T3a!$(openssl rand -hex 18)" '{"lab-reader":$reader,"lab-outsider":$outsider,"lab-app":$app}' \
  > "$LAB_RUNTIME/test-passwords.json"
```

На хосте GitLab настройте JWT для `vault-01`, используя временно `root_token` из защищённого файла `vault-init.json` на Vault VM. [GitLab ID tokens и Vault](https://docs.gitlab.com/ci/secrets/hashicorp_vault/)

```bash
read -rsp 'Vault bootstrap token: ' vault_token
printf '\n'
vapi() {
  local method=$1 path=$2
  shift 2
  curl -fsS --cacert "$vault_ca" -X "$method" -H 'Content-Type: application/json' \
    -H "X-Vault-Namespace: $vault_namespace" -H @<(printf 'X-Vault-Token: %s\n' "$vault_token") \
    "$vault_url/v1/$path" "$@"
}
issuer=$(curl -fsS --cacert "$gitlab_ca" "$gitlab_url/.well-known/openid-configuration" | jq -er .issuer)
mount_type=$(vapi GET sys/auth | jq -r '(.data // .)["gitlab-jwt/"].type // ""')
if [[ -z $mount_type ]]; then
  vapi POST sys/auth/gitlab-jwt --data '{"type":"jwt"}'
else
  [[ $mount_type == jwt ]] &&
    vapi GET auth/gitlab-jwt/config | jq -e --arg issuer "$issuer" '.data.bound_issuer == $issuer' ||
    exit 1
fi
jq -nc --arg url "$gitlab_url" --arg issuer "$issuer" --rawfile ca "$gitlab_ca" \
  '{oidc_discovery_url:$url,bound_issuer:$issuer,oidc_discovery_ca_pem:$ca}' |
  vapi POST auth/gitlab-jwt/config --data-binary @-
for phase in plan apply; do
  action=verify; policies='["terraform-ad-plan"]'
  if [[ $phase == apply ]]; then action=start; policies='["terraform-ad-plan","terraform-ad-apply"]'; fi
  if existing=$(vapi GET "auth/gitlab-jwt/role/terraform-$phase" 2>/dev/null); then
    jq -e --arg project "$project_id" --arg env "vault/$vault_id" \
      '.data.bound_claims | .project_id == $project and .environment == $env' <<<"$existing" >/dev/null || exit 1
  fi
  jq -nc --rawfile policy "config/vault/terraform-$phase.hcl" '{policy:$policy}' |
    vapi PUT "sys/policies/acl/terraform-ad-$phase" --data-binary @-
  jq -nc --arg aud "$gitlab_url/terraform/vault/$phase" --arg project "$project_id" \
    --arg branch "$branch" --arg env "vault/$vault_id" --arg action "$action" --argjson policies "$policies" \
    '{role_type:"jwt",user_claim:"sub",bound_audiences:[$aud],bound_claims:{project_id:$project,ref_type:"branch",ref:$branch,ref_protected:"true",environment:$env,environment_action:$action},token_policies:$policies,token_explicit_max_ttl:900}' |
    vapi POST "auth/gitlab-jwt/role/terraform-$phase" --data-binary @-
done
unset vault_token
```

## 6. Применение и проверка

В **Build → Pipelines → New pipeline** выберите `Test`, проверьте планы без удалений и вручную запустите `ad:apply`, затем `vault:apply: [vault-01]`.

Проверьте LDAP-доступ читателя, отказ постороннему пользователю и успешный LDAPS-вход с ротированным паролем.

```bash
login() {
  jq -ce --arg user "$1" '{password:.[$user]}' "$LAB_RUNTIME/test-passwords.json" |
    curl -fsS --cacert "$vault_ca" -H "Content-Type: application/json" --data-binary @- "$vault_url/v1/auth/ad-ldap/login/$1" |
    jq -er .auth.client_token
}
reader=$(login lab-reader)
outsider=$(login lab-outsider)
secret_url="$vault_url/v1/ad-creds/static-cred/lab-app"
test "$(curl -sS --cacert "$vault_ca" -o /dev/null -w '%{http_code}' -H @<(printf 'X-Vault-Token: %s\n' "$outsider") "$secret_url")" = 403
secret() {
  curl -fsS --cacert "$vault_ca" -H @<(printf 'X-Vault-Token: %s\n' "$reader") "$secret_url" | jq -er .data.password
}
before=$(secret)
sleep 65
after=$(secret)
test "$before" != "$after"
printf '%s' "$after" | LDAPTLS_CACERT="$ad_ca" ldapwhoami -x -H "ldaps://$LAB_AD_HOST:636" -D lab-app@lab.example -y /dev/stdin
unset reader outsider before after
```

В GitLab проверьте отдельные state `ad-lab` и `vault-vault-01`, затем запустите новый pipeline и убедитесь, что оба плана показывают `No changes`.
