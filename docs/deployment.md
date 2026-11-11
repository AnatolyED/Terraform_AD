# Ручное развёртывание · main

Debian 12 amd64 запускает Runner, а GitLab, AD и Vault уже работают в корпоративном контуре.

Выполняйте блоки по порядку в одном Bash-сеансе и подставьте значения в угловых скобках.

## 1. Пакеты и образы

Установите [зависимости Debian](platform.md#зависимости-debian) и загрузите образы Runner после проверки контрольных сумм.

```bash
bundle=/home/aed/terraform-ad-offline
(cd "$bundle" && sha256sum -c SHA256SUMS)
sudo docker load -i "$bundle/runner-images.tar"
git clone -b main "$bundle/Terraform_AD-debian12.bundle" /home/aed/Terraform_AD
cd /home/aed/Terraform_AD
```

## 2. Проект и инвентарь

Создайте пустой закрытый проект GitLab 18.6+, отправьте исходный код и защитите `main` после первого push.

```bash
gitlab_url='https://<GITLAB_FQDN>'
gitlab_ca='/path/to/gitlab-ca.pem'
project_id='<GITLAB_PROJECT_ID>'
branch=main
git remote add workgit "$gitlab_url/<GROUP>/<PROJECT>.git"
git -c http.sslCAInfo="$gitlab_ca" push -o ci.skip workgit HEAD:refs/heads/main
```

Заполните в закрытом GitLab файлы `ou.yaml`, `groups.yaml`, `users.yaml` в `data/active-directory/production/`, а кластеры — в `data/vault/clusters.yaml`. [Схема YAML](configuration.md)

## 3. Runner

Задайте параметры сети и выполните [регистрацию Runner](platform.md#регистрация-runner).

```bash
runner_network=bridge
runner_hosts=()
```

## 4. Active Directory

Делегируйте через `dsa.msc` права Terraform только в выделенной OU, выделите две отдельные bind-учётки Vault и ограничьте Reset Password сервисными учётками каждой роли.

```bash
ad_fqdn='<AD_FQDN>'
ad_ca='/path/to/ad-ca.pem'
openssl s_client -brief -connect "$ad_fqdn:636" -servername "$ad_fqdn" \
  -verify_hostname "$ad_fqdn" -verify_return_error -CAfile "$ad_ca" </dev/null
LDAPTLS_CACERT="$ad_ca" ldapwhoami -x -H "ldaps://$ad_fqdn:636" -D '<TERRAFORM_BIND_UPN>' -W
```

В **Settings → CI/CD → Variables** заполните переменные AD со scope `ad/production` и переменные каждого Vault со scope `vault/<ID>`, задав PEM как File, а пароли как Protected и Masked/Hidden. [Точные имена и форматы](configuration.md#2-опции-запуска)

## 5. Vault и JWT

Для каждого действующего Vault задайте параметры и выполните [настройку JWT](platform.md#jwt-для-vault).

```bash
vault_url='https://<VAULT_FQDN>:8200'
vault_ca='/path/to/vault-ca.pem'
vault_id=vault-01
vault_namespace=''
```

## 6. State, план и применение

Включите GitLab-managed state, сохраните резервную копию существующего state и перед первым планом импортируйте уже управляемые объекты AD и Vault в соответствующие state. [Команды импорта AD](operations.md#импорт-ad) · [Команды импорта Vault](operations.md#импорт-vault)

Для ручного импорта откройте Terraform CLI с тем же зеркалом и подставьте доступные из контейнера пути к CA.

```bash
sudo docker run --rm -it --pull never --entrypoint /bin/sh \
  -v "$PWD:/project" -v "$bundle/provider-mirror:/providers:ro" \
  -v "$(dirname "$gitlab_ca"):/certs:ro" -w /project terraform-ad/terraform:1.17.1
```

При обновлении перенесите заполненные YAML в новый каталог одним merge request и сформируйте новые планы.

Включите `AD_DEPLOY_ENABLED=true`, задайте `AD_DEPLOY_ENVIRONMENT=production` и выберите `VAULT_DEPLOY_MODE=single` с `VAULT_TARGET_ID=vault-01` для первого Vault или `all` для всей матрицы.

```bash
git add -- data/
git commit -m 'Configure AD and Vault inventory'
git -c http.sslCAInfo="$gitlab_ca" push -u workgit HEAD:refs/heads/configure-inventory
```

Создайте merge request и после merge проверьте сохранённые планы, затем запустите вручную `ad:apply` и `vault:apply` по выбранным кластерам.

## 7. Приёмка

Войдите в каждый Vault тестовым читателем и проверьте ожидаемую политику.

```bash
reader='<AD_SAM_ACCOUNT_NAME>'
read -rsp 'LDAP password: ' reader_password
printf '\n'
printf '%s' "$reader_password" | jq -Rsc '{password:.}' |
  curl -fsS --cacert "$vault_ca" -H 'Content-Type: application/json' --data-binary @- \
    "$vault_url/v1/auth/ad-ldap/login/$reader" |
  jq -e --arg policy 'ad-<POLICY_KEY>' '.auth.policies | index($policy) != null'
unset reader_password
```

Для каждой роли проверьте вход в AD с новым паролем после ротации и повторный план `No changes` для `ad-production` и каждого `vault-<ID>`.
