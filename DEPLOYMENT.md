# Развёртывание и подключение к действующим AD и Vault

## 1. Подготовка контура

Создайте закрытый GitLab-проект `<GITLAB_PROJECT_PATH>`, перенесите в него рабочую ветку и защитите ветку по умолчанию `<DEFAULT_BRANCH>`. Используйте GitLab 18.6+ и Docker Runner Linux x86-64. Зарегистрируйте Runner проверок с тегом `terraform-docker`. Для `terraform-deploy` используйте отдельный защищённый Runner, привязанный к проекту. Ограничьте право запуска `apply` владельцами развёртывания. Оставьте `AD_DEPLOY_ENABLED=false` и `VAULT_DEPLOY_MODE=off` на время подготовки.

Включите GitLab-managed Terraform state и доступ к Package Registry, если используется внутренний пакет. Проверьте HTTPS-доступ Runner к `<GITLAB_URL>` и к каждому `<VAULT_API_URL>`, доступ к `<AD_FQDN>:636` и доступ Vault к LDAPS и OIDC discovery GitLab. Настройте доверие к цепочкам CA. Сверьте время GitLab, Runner, Vault и AD.

Подготовьте образ Terraform из `.gitlab-ci.yml`. При закрытом доступе к Docker Hub загрузите образ в согласованный реестр или перенесите его через `docker image save` и `docker image load`. Укажите доступный образ с проверенным digest в CI. Зеркало Docker-пакетов Яндекса предназначено для установки Docker Engine. Для OCI-образов используйте реестр или архив. Для провайдеров используйте `config/terraform.tfrc` или передайте альтернативную конфигурацию через GitLab File-переменную `TF_CLI_CONFIG_FILE`. Во всех случаях сохраните проверку `.terraform.lock.hcl`.

## 2. Действующий Active Directory

1. Выделите существующую родительскую OU `<MANAGED_BASE_DN>`. Укажите её DN, например `OU=<MANAGED_OU>,DC=<DOMAIN_COMPONENT>,DC=<TLD>`. Создайте отдельную учётку `<TERRAFORM_BIND_UPN>` для Terraform.
2. Делегируйте в этой ветке чтение объектов, создание и изменение OU, пользователей и групп, запись `member`, необходимые права Reset Password и чтение и запись DACL управляемых OU. Убедитесь, что учётка Terraform не получает `Delete Child` для управляемых OU на родителях и `Delete Tree` на предках. Проверьте запрет удаления на одноразовой пустой OU в тестовой ветке.
3. Заполните `inventory/active-directory/production/`. Сохраните стабильные ключи YAML. Укажите текущие имена и свойства существующих объектов. Проверьте полный состав каждой группы с `membership`. Порядок и примеры приведены в [настройках](CONFIGURATION.md).
4. В scope `ad/production` установите `AD_USERNAME`, `AD_PASSWORD`, `AD_TLS_CA_CERT_FILE`, `TF_VAR_ad_ldap_url` и `TF_VAR_ad_managed_base_dn`. При создании активных пользователей передайте `TF_VAR_ad_user_passwords`. Установите `AD_DEPLOY_ENVIRONMENT=production`.

## 3. GitLab state и импорт AD

Для переноса существующего state сначала сохраните резервную копию. Выполните `terraform init -migrate-state` с параметрами целевого backend в согласованное окно. Для нового state существующие объекты импортируйте по `objectGUID` перед первым применением. Следующий пример выполняется в Bash из корня проекта. Используйте защищённый операторский токен GitLab с доступом к state.

```sh
export TF_CLI_CONFIG_FILE="$PWD/config/terraform.tfrc"
export TF_HTTP_ADDRESS='<GITLAB_URL>/api/v4/projects/<GITLAB_PROJECT_ID>/terraform/state/ad-production'
export TF_HTTP_LOCK_ADDRESS="$TF_HTTP_ADDRESS/lock"
export TF_HTTP_UNLOCK_ADDRESS="$TF_HTTP_ADDRESS/lock"
export TF_HTTP_LOCK_METHOD=POST
export TF_HTTP_UNLOCK_METHOD=DELETE
export TF_HTTP_USERNAME='<GITLAB_USERNAME>'
read -rs TF_HTTP_PASSWORD
export TF_HTTP_PASSWORD
export TF_VAR_ad_inventory_environment=production
terraform -chdir=infra/active-directory init -reconfigure -lockfile=readonly
terraform -chdir=infra/active-directory import 'module.directory.ad_ou.top_level["<OU_KEY>"]' '<OU_GUID>'
terraform -chdir=infra/active-directory import 'module.directory.ad_ou.child["<CHILD_OU_KEY>"]' '<CHILD_OU_GUID>'
terraform -chdir=infra/active-directory import 'module.directory.ad_user.directory["<USER_KEY>"]' '<USER_GUID>'
terraform -chdir=infra/active-directory import 'module.directory.ad_group.directory["<GROUP_KEY>"]' '<GROUP_GUID>'
terraform -chdir=infra/active-directory import 'module.directory.ad_group_membership.directory["<GROUP_KEY>"]' '<GROUP_GUID>'
unset TF_HTTP_PASSWORD
```

Перед импортом передайте переменные подключения и CA из [настроек](CONFIGURATION.md). Импортируйте членство только для групп, чей состав задан YAML. При изменении адреса ресурса используйте `moved`. Если предыдущий сбой пометил OU для замены, сначала проверьте GUID, DACL и состояние на отдельной копии state.

## 4. Действующие Vault

1. Для каждого `<VAULT_CLUSTER_ID>` укажите фактический HTTPS API в `inventory/vault/clusters.yaml`. Для рабочего AD используйте `ad_environment: production`. У каждого экземпляра должна быть своя учётка для ротации. Сопоставьте Vault-политики с реальными группами AD и проверьте, что YAML ограничивает чтение нужными API-путями.
2. Создайте учётку `<VAULT_LDAP_AUTH_BIND_DN>` для чтения каталога и отдельную `<VAULT_LDAP_SECRETS_BIND_DN>` для сброса паролей только выделенных сервисных учёток. В GitLab используйте scope `vault/<VAULT_CLUSTER_ID>` и переменные из [настроек](CONFIGURATION.md).
3. На каждом Vault настройте JWT mount и две роли. Используйте операторский токен с доступом к настройке JWT и политик. Если `gitlab-jwt` уже существует, проверьте его issuer и роли перед записью. Сверьте `issuer` с `iss` GitLab ID token. При корпоративном CA передайте `oidc_discovery_ca_pem=@<GITLAB_CA_PEM>`.

```sh
export VAULT_ADDR='<VAULT_API_URL>'
export VAULT_CACERT='<VAULT_CA_PEM>'
gitlab_url='<GITLAB_URL>'
gitlab_project_id='<GITLAB_PROJECT_ID>'
default_branch='<DEFAULT_BRANCH>'
cluster='<VAULT_CLUSTER_ID>'

vault auth enable -path=gitlab-jwt jwt
vault write auth/gitlab-jwt/config oidc_discovery_url="$gitlab_url" bound_issuer="$gitlab_url"
vault policy write terraform-ad-plan config/vault/terraform-plan.hcl
vault policy write terraform-ad-apply config/vault/terraform-apply.hcl

for phase in plan apply; do
  action=verify
  policies='"terraform-ad-plan"'
  if [ "$phase" = apply ]; then
    action=start
    policies='"terraform-ad-plan","terraform-ad-apply"'
  fi
  vault write "auth/gitlab-jwt/role/terraform-$phase" - <<EOF
{
  "role_type": "jwt",
  "user_claim": "sub",
  "bound_audiences": ["$gitlab_url/terraform/vault/$phase"],
  "bound_claims": {
    "project_id": "$gitlab_project_id",
    "ref_type": "branch",
    "ref": "$default_branch",
    "ref_protected": "true",
    "environment": "vault/$cluster",
    "environment_action": "$action"
  },
  "token_policies": [$policies],
  "token_explicit_max_ttl": 900
}
EOF
done
```

4. Проверьте существующие mount paths `auth/ad-ldap` и `ad-creds`. Для занятого пути импортируйте ресурсы в state этого кластера. Повторите экспорт `TF_HTTP_*` из примера AD, заменив имя state на `vault-<VAULT_CLUSTER_ID>`, и передайте все переменные Vault из scope этого кластера. Для локального импорта используйте `TF_VAR_vault_use_gitlab_jwt=false` и ограниченный `VAULT_TOKEN`.

```sh
export TF_VAR_vault_cluster_id='<VAULT_CLUSTER_ID>'
terraform -chdir=infra/vault init -reconfigure -lockfile=readonly
terraform -chdir=infra/vault import vault_ldap_auth_backend.directory ad-ldap
terraform -chdir=infra/vault import vault_ldap_secret_backend.directory ad-creds/config
terraform -chdir=infra/vault import vault_password_policy.directory terraform-ad-credentials
terraform -chdir=infra/vault import 'vault_policy.directory["<POLICY_KEY>"]' 'ad-<POLICY_KEY>'
terraform -chdir=infra/vault import 'vault_ldap_auth_backend_group.directory["<GROUP_KEY>"]' 'auth/ad-ldap/groups/<GROUP_SAM>'
terraform -chdir=infra/vault import 'vault_ldap_secret_backend_static_role.directory["<ROLE_KEY>"]' 'ad-creds/static-role/<ROLE_KEY>'
```

Сверьте существующие политики и текущие bind-пароли перед импортом. Первое создание статической роли меняет пароль сервисной учётки. Подготовьте приложение к получению текущего пароля через Vault.

## 5. Пилот и первое применение

Официальный `isometry/ad` 0.5.0 воспроизвёл ошибку чтения защиты OU под делегированной учёткой. Перед живым применением инвентаря с защищёнными OU проверьте исправленную версию в тестовом контуре. Отдельный патч и порядок подключения хранятся в каталоге `fix` ветки `Test`.

1. Начните с тестового AD и Vault, подготовленных тем же способом. Установите `AD_DEPLOY_ENVIRONMENT=lab`, `AD_DEPLOY_ENABLED=true` и `VAULT_DEPLOY_MODE=lab`. Этот режим включает только строку `vault-01`, поэтому она должна указывать на тестовый Vault и тестовый инвентарь.
2. В `ad:plan` проверьте OU, GUID импортированных объектов, полный состав групп и операции с паролями. В `vault:plan` проверьте адрес кластера, политики, LDAP mounts и роли. Запустите ручной `ad:apply`, затем `vault:apply` для сохранённых планов того же pipeline.
3. Подтвердите LDAP-вход, политику группы, чтение статического секрета, отказ для пользователя вне группы и успешный LDAPS-вход сервисной учётки после ротации. Повторный план должен показать `No changes`.
4. Перед production подтвердите готовность исправленного AD-провайдера, действующее делегирование, резервную копию state и импорт существующих объектов. Заполните все production адреса. Установите `AD_DEPLOY_ENVIRONMENT=production` и согласуйте включение `VAULT_DEPLOY_MODE=all`. Сверьте план каждого кластера перед его `apply`.

## 6. Штатное обновление и восстановление

Изменяйте YAML через merge request. После merge проверяйте новый сохранённый план. При истечении артефакта, изменении state или частичном применении сформируйте новый план. В случае частичного создания импортируйте реальные объекты, которых ещё нет в state. Для отката используйте revert и проверенный новый план. После ротации актуальные учётные данные получайте из Vault. Пароли, токены, state и артефакты plan храните в закрытом контуре.
