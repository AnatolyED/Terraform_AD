# Развёртывание Terraform AD

Debian 12 amd64 запускает GitLab Runner, Windows Server 2022 обслуживает AD DS, а GitLab и Vault уже запущены. Значения ниже относятся к локальному стенду `aed.adm`.

## 1. Установить зависимости

Выберите официальный APT-репозиторий Docker или зеркало Яндекса, затем установите Docker и диагностические утилиты.

```bash
sudo apt update
sudo apt install -y ca-certificates curl git jq ldap-utils
docker_apt=https://download.docker.com/linux/debian
sudo install -d -m 0755 /etc/apt/keyrings
sudo curl -fsS "$docker_apt/gpg" -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
printf 'deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] %s bookworm stable\n' "$docker_apt" |
  sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io
sudo systemctl enable --now docker
sudo docker version
```

Для зеркала замените значение `docker_apt` на `https://mirror.yandex.ru/mirrors/download.docker.com/linux/debian`.

## 2. Подготовить проект GitLab

Создайте закрытый проект GitLab 18.6 или новее. После push сделайте `main` веткой по умолчанию, защитите её и включите GitLab-managed Terraform state.

```bash
git clone -b main https://github.com/AnatolyED/Terraform_AD.git
cd Terraform_AD
gitlab=https://gitlab.aed.adm:8929
gitlab_ca="$HOME/adm-ca.pem"
git remote add workgit "$gitlab/root/terraformd-ad-adm.git"
git -c http.sslCAInfo="$gitlab_ca" push -o ci.skip workgit main
```

Для нового проекта замените путь `root/terraformd-ad-adm.git`. Проверьте DNS и адреса в `config/config.toml`. Запись GitLab с `host-gateway` рассчитана на GitLab, опубликованный на том же Docker-хосте. Для внешнего GitLab используйте DNS.

## 3. Зарегистрировать Runner

В **Settings → CI/CD → Runners** создайте два проектных Runner с тегами `terraform-docker` и `terraform-deploy`, отключите **Run untagged** и включите **Protected** для второго.

```bash
runner_image=gitlab/gitlab-runner:alpine-v19.5.1
runner_dir=/srv/gitlab-runner/terraform-ad
sudo install -d -m 0700 "$runner_dir"
sudo install -m 0600 config/config.toml "$runner_dir/template.toml"
sudo install -m 0600 "$gitlab_ca" "$runner_dir/gitlab-ca.pem"
sudo docker run -d --name terraform-ad-runner --restart unless-stopped \
  --add-host gitlab.aed.adm:host-gateway \
  -v "$runner_dir:/etc/gitlab-runner" -v /var/run/docker.sock:/var/run/docker.sock "$runner_image"
```

Дважды выполните регистрацию, передавая соответствующий токен `glrt-…` по запросу. Укажите URL GitLab, executor `docker` и образ `hashicorp/terraform:1.17.1`.

```bash
sudo docker exec -it terraform-ad-runner gitlab-runner register \
  --tls-ca-file /etc/gitlab-runner/gitlab-ca.pem --template-config /etc/gitlab-runner/template.toml
sudo docker exec terraform-ad-runner gitlab-runner verify
```

Для существующего Runner перенесите настройки Docker из шаблона в его `config.toml` и проверьте регистрацию. Файл с токенами хранится на сервере Runner.

| Источник | Настройка |
| --- | --- |
| Официальные провайдеры | `TERRAFORM_SOURCE=upstream` по умолчанию или `yandex` для зеркала Vault provider |
| Исправленный AD provider | ZIP скачивается из [GitHub Release](https://github.com/AnatolyED/terraform-provider-ad-ou-dacl/releases/tag/v0.6.0-ou-dacl.1). При блокировке GitHub задайте `AD_PROVIDER_RELEASE_URL` с HTTPS-адресом копии того же ZIP |
| Docker-образы | По умолчанию используются исходные реестры. Для своего [Yandex Cloud Registry](https://yandex.cloud/en/docs/cloud-registry/concepts/registry) задайте адрес образа Runner в `runner_image`, Terraform в `TERRAFORM_IMAGE`, helper в `helper_image` шаблона Runner |

Для приватного Docker Registry настройте учётные данные на Docker-хосте и `DOCKER_AUTH_CONFIG` для Runner. При выборе другого источника сохраняйте версии образов. Helper должен соответствовать версии Runner и архитектуре AMD64. При инициализации проверяется SHA-256 исправленного ZIP и используется `-lockfile=readonly`.

## 4. Подключить AD

В AD делегируйте учётке Terraform управление под `OU=TerraformADM,DC=aed,DC=adm`, а отдельной учётке Vault — чтение для LDAP auth и отдельной учётке ротации — Reset Password для сервисных записей.

```bash
LDAPTLS_CACERT="$HOME/ad-ca-aed-adm.pem" \
  ldapwhoami -x -H ldaps://dc01.aed.adm:636 -D svc-terraform@aed.adm -W
```

Добавьте переменные GitLab со scope `ad/adm`. Используйте тип **File** для PEM и **Protected, Masked and hidden** для секретов.

| Ключ | Значение |
| --- | --- |
| `AD_USERNAME`, `AD_PASSWORD` | `svc-terraform@aed.adm` и пароль делегированной учётки |
| `AD_TLS_CA_CERT_FILE` | PEM цепочки CA AD |
| `TF_VAR_ad_ldap_url` | `ldaps://dc01.aed.adm:636` |
| `TF_VAR_ad_managed_base_dn` | `OU=TerraformADM,DC=aed,DC=adm` |
| `TF_VAR_ad_user_passwords` | JSON начальных паролей по ключам `adm-reader`, `adm-outsider`, `adm-app` |

Проверьте `data/active-directory/adm/` перед планом: поле `membership` управляет полным составом указанной группы.

## 5. Подключить Vault

На хосте Vault проверьте доступ к OIDC GitLab по HTTPS. Команды выполняйте из корня проекта с Vault CLI 2.2.1 и операторским токеном.

```bash
export VAULT_ADDR=https://vault.aed.adm:8200
export VAULT_CACERT="$HOME/vault-ca.pem"
issuer=$(curl -fsS --cacert "$gitlab_ca" "$gitlab/.well-known/openid-configuration" | jq -er .issuer)
read -rsp 'Vault token: ' VAULT_TOKEN
printf '\n'
export VAULT_TOKEN
vault auth list
```

Если `gitlab-jwt/` свободен, включите JWT и задайте доверие к GitLab. Для существующего mount сначала сверяйте issuer и владельца ролей.

```bash
vault auth enable -path=gitlab-jwt jwt
vault write auth/gitlab-jwt/config oidc_discovery_url="$gitlab" bound_issuer="$issuer" \
  oidc_discovery_ca_pem=@"$gitlab_ca"
vault policy write terraform-ad-plan config/vault/terraform-plan.hcl
vault policy write terraform-ad-apply config/vault/terraform-apply.hcl
```

Создайте роли с ограничениями по числовому ID проекта, защищённой ветке и окружению конкретного Vault.

```bash
project_id='<GITLAB_PROJECT_ID>'
vault_id=vault-01
for phase in plan apply; do
  action=verify
  policies=terraform-ad-plan
  if [ "$phase" = apply ]; then action=start; policies=terraform-ad-plan,terraform-ad-apply; fi
  jq -n --arg aud "$gitlab/terraform/vault/$phase" --arg project "$project_id" \
    --arg env "vault/$vault_id" --arg action "$action" --arg policies "$policies" \
    '{role_type:"jwt",user_claim:"sub",bound_audiences:[$aud],bound_claims:{project_id:$project,ref_type:"branch",ref:"main",ref_protected:"true",environment:$env,environment_action:$action},token_policies:($policies|split(",")),token_explicit_max_ttl:900}' |
    vault write "auth/gitlab-jwt/role/terraform-$phase" -
done
unset VAULT_TOKEN
```

Добавьте переменные со scope `vault/vault-01`. Для остальных кластеров повторите настройку и добавьте их идентификаторы в `data/vault/clusters.yaml` и матрицу CI.

| Ключ | Значение |
| --- | --- |
| `VAULT_CACERT`, `TF_VAR_vault_ldap_ca_file` | PEM цепочек CA Vault и AD, тип File |
| `TF_VAR_vault_ldap_url` | `ldaps://dc01.aed.adm:636` |
| `TF_VAR_vault_ldap_auth_bind_dn`, `TF_VAR_vault_ldap_auth_bind_password` | DN и пароль учётки чтения |
| `TF_VAR_vault_ldap_auth_user_dn` | `OU=Identity,OU=TerraformADM,DC=aed,DC=adm` |
| `TF_VAR_vault_ldap_auth_group_dn` | `OU=Groups,OU=Identity,OU=TerraformADM,DC=aed,DC=adm` |
| `TF_VAR_vault_ldap_secrets_bind_dn`, `TF_VAR_vault_ldap_secrets_bind_password` | DN и пароль учётки ротации |
| `TF_VAR_vault_ldap_secrets_user_dn` | `OU=Services,OU=Identity,OU=TerraformADM,DC=aed,DC=adm` |

## 6. Проверить state и применить планы

Сначала запустите пайплайн `main` с настройками по умолчанию и убедитесь, что `ad:validate` и `vault:validate` прошли.

Если объекты уже существуют, сохраните резервную копию state и импортируйте объекты с Terraform 1.17.1 на Linux amd64. Передайте параметры подключения из шагов 4 и 5 и выберите state `ad-adm` или `vault-<ID>`.

```bash
export TF_VAR_inventory_root="$PWD/data"
export TF_VAR_ad_inventory_environment=adm
export TF_HTTP_USERNAME='<GITLAB_USERNAME>'
read -rsp 'GitLab token with state access: ' TF_HTTP_PASSWORD
printf '\n'
export TF_HTTP_PASSWORD
export TF_HTTP_LOCK_METHOD=POST TF_HTTP_UNLOCK_METHOD=DELETE
state_backend() {
  export TF_HTTP_ADDRESS="$gitlab/api/v4/projects/$project_id/terraform/state/$1"
  export TF_HTTP_LOCK_ADDRESS="$TF_HTTP_ADDRESS/lock"
  export TF_HTTP_UNLOCK_ADDRESS="$TF_HTTP_ADDRESS/lock"
}
state_backend ad-adm
sh config/terraform-init.sh infra/active-directory -reconfigure
terraform -chdir=infra/active-directory import 'module.directory.ad_ou.top_level["identity"]' '<OBJECT_GUID>'
state_backend vault-vault-01
export TF_VAR_vault_cluster_id=vault-01
sh config/terraform-init.sh infra/vault -reconfigure
terraform -chdir=infra/vault import vault_ldap_auth_backend.directory ad-ldap
unset TF_HTTP_PASSWORD VAULT_TOKEN
```

Для ручного импорта Vault задайте `TF_VAR_vault_use_gitlab_jwt=false` и передайте операторский `VAULT_TOKEN`. Для backend GitLab с частным CA добавьте сертификат в системное доверенное хранилище Debian.

| Порядок | Параметры пайплайна | Действие |
| --- | --- | --- |
| 1. AD | `AD_DEPLOY_ENABLED=true`, `AD_DEPLOY_ENVIRONMENT=adm`, `VAULT_DEPLOY_MODE=off` | Проверьте `ad:plan` и вручную запустите `ad:apply` |
| 2. Vault | `AD_DEPLOY_ENABLED=false`, `VAULT_DEPLOY_MODE=single`, `VAULT_TARGET_ID=vault-01` | Проверьте `vault:plan` и вручную запустите `vault:apply` |

Перед первым применением проверьте неожиданные удаления и замены. Первое создание статической роли меняет пароль сервисной учётки.

## 7. Принять результат

1. В AD проверьте OU, защиту от случайного удаления и состав группы `vault-readers`.
2. В Vault войдите как `adm-reader`, проверьте политику `ad-adm-app-read` и получение `ad-creds/static-cred/adm-app`; проверьте отсутствие доступа к секрету у `adm-outsider`.
3. После ротации проверьте вход в AD новым паролем сервисной учётки.
4. Повторите планы и проверьте `No changes`, затем убедитесь, что в GitLab есть отдельные state `ad-adm` и `vault-vault-01`.
