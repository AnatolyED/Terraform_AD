# State и сопровождение

## Импорт AD

Для переноса существующего state сначала сохраните резервную копию. Выполните `terraform init -migrate-state` с параметрами целевого backend в согласованное окно. Для нового state существующие объекты импортируйте по `objectGUID` перед первым применением. Следующий пример выполняется в Bash из корня проекта. Используйте защищённый операторский токен GitLab с доступом к state.

```sh
export TF_CLI_CONFIG_FILE="$PWD/config/terraform.tfrc"
export TF_HTTP_ADDRESS='<GITLAB_URL>/api/v4/projects/<GITLAB_PROJECT_ID>/terraform/state/ad-<AD_DEPLOY_ENVIRONMENT>'
export TF_HTTP_LOCK_ADDRESS="$TF_HTTP_ADDRESS/lock"
export TF_HTTP_UNLOCK_ADDRESS="$TF_HTTP_ADDRESS/lock"
export TF_HTTP_LOCK_METHOD=POST
export TF_HTTP_UNLOCK_METHOD=DELETE
export TF_HTTP_USERNAME='<GITLAB_USERNAME>'
read -rs TF_HTTP_PASSWORD
export TF_HTTP_PASSWORD
export TF_VAR_ad_inventory_environment='<AD_DEPLOY_ENVIRONMENT>'
export TF_VAR_inventory_root="$PWD/data"
terraform -chdir=infra/active-directory init -reconfigure -lockfile=readonly
terraform -chdir=infra/active-directory import 'module.directory.ad_ou.top_level["<OU_KEY>"]' '<OU_GUID>'
terraform -chdir=infra/active-directory import 'module.directory.ad_ou.child["<CHILD_OU_KEY>"]' '<CHILD_OU_GUID>'
terraform -chdir=infra/active-directory import 'module.directory.ad_user.directory["<USER_KEY>"]' '<USER_GUID>'
terraform -chdir=infra/active-directory import 'module.directory.ad_group.directory["<GROUP_KEY>"]' '<GROUP_GUID>'
terraform -chdir=infra/active-directory import 'module.directory.ad_group_membership.directory["<GROUP_KEY>"]' '<GROUP_GUID>'
unset TF_HTTP_PASSWORD
```

Перед импортом передайте переменные подключения и CA из [настроек](configuration.md). Импортируйте членство только для групп, чей состав задан YAML. При изменении адреса ресурса используйте `moved`. Если предыдущий сбой пометил OU для замены, сначала проверьте GUID, DACL и состояние на отдельной копии state.

## Импорт Vault

Проверьте существующие mount paths `auth/ad-ldap` и `ad-creds`. Для занятого пути импортируйте ресурсы в state этого кластера. Повторите экспорт `TF_HTTP_*` из примера AD, заменив имя state на `vault-<VAULT_CLUSTER_ID>`, и передайте все переменные Vault из scope этого кластера. Для локального импорта используйте `TF_VAR_vault_use_gitlab_jwt=false` и ограниченный `VAULT_TOKEN`.

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

## Обновление и восстановление

Изменяйте YAML через merge request. После merge проверяйте новый сохранённый план. При истечении артефакта, изменении state или частичном применении сформируйте новый план. В случае частичного создания импортируйте реальные объекты, которых ещё нет в state. Для отката используйте revert и проверенный новый план. После ротации актуальные учётные данные получайте из Vault. Пароли, токены, state и артефакты plan храните в закрытом контуре.
