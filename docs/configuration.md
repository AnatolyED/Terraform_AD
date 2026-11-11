# Сущности и настройки

## 1. Сущности инвентаря

Для рабочего контура используйте окружение production, для стенда — adm.

ADM — короткое имя домена в примерах, `adm.example` — условное DNS-имя. Ключи `services`, `app-readers` и `app-service` стабильны. Ссылки в YAML используют эти ключи.

`data/active-directory/<окружение>/ou.yaml`

```yaml
services:
  name: Services
  description: Managed service accounts
```

`name` задаёт RDN OU. Для дочерней OU задайте `parent_id` с ключом OU верхнего уровня. Поддерживаются два уровня под делегированной OU.

`data/active-directory/<окружение>/users.yaml`

```yaml
app-service:
  name: Application Service
  sam_account_name: app-service
  principal_name: app-service@adm.example
  ou_id: services
  enabled: true
  change_password_at_logon: false
  password_version: 0
```

Для новой активной записи передайте начальный пароль через `TF_VAR_ad_user_passwords`. После передачи записи в Vault управление паролем выполняет Vault. Дополнительные поля пользователя — `display_name`, `given_name`, `surname`, `email_address` и `description`.

`data/active-directory/<окружение>/groups.yaml`

```yaml
app-readers:
  name: Application Readers
  sam_account_name: app-readers
  ou_id: services
  scope: global
  category: security
  membership:
    user_ids: []
    group_ids: []
```

`membership` задаёт полный состав прямых участников по ключам YAML. Два пустых списка очищают состав. Если поле пропущено, состав группы контролируется в AD. Перед применением заполните списки фактическими читателями. Для ротации используйте отдельную сервисную учётку.

`data/vault/clusters.yaml`

```yaml
vault-01:
  address: https://vault-01.adm.example
  ad_environment: production
  auth_bind_password_version: 1
  secrets_bind_password_version: 1
  policies:
    app-read:
      ad-creds/static-cred/app-service: [read]
  group_policies:
    app-readers: [app-read]
  static_roles:
    app-service:
      user_id: app-service
      rotation_period_seconds: 86400
```

Адрес каждого Vault уникален. Политика получит имя `ad-app-read`. Ключ группы указывает на группу AD категории `security`. Для одной учётки AD допустима одна роль ротации в пределах окружения. Для нового кластера добавьте его ключ и в YAML, и в матрицу `.gitlab-ci.yml`.

## 2. Опции запуска

| Переменная GitLab | Значение |
| --- | --- |
| `AD_DEPLOY_ENABLED` | `false` по умолчанию. `true` включает `ad:plan` и `ad:apply` |
| `AD_DEPLOY_ENVIRONMENT` | `production` по умолчанию. Область `ad/<окружение>` и state `ad-<окружение>` |
| `VAULT_DEPLOY_MODE` | `off` по умолчанию, `single` включает выбранный Vault, `all` включает все строки матрицы |
| `VAULT_TARGET_ID` | Ключ строки матрицы для режима `single` |
| `TF_CLI_CONFIG_FILE` | Необязательная GitLab-переменная типа File. Задаёт собственную конфигурацию источников провайдеров |

### AD

Задайте переменные с областью `ad/<окружение>`.

| Переменная | Значение |
| --- | --- |
| `AD_USERNAME` | UPN или DN делегированной учётки Terraform |
| `AD_PASSWORD` | Пароль этой учётки |
| `AD_TLS_CA_CERT_FILE` | PEM цепочки CA, тип File |
| `TF_VAR_ad_ldap_url` | `ldaps://<AD_FQDN>:636` |
| `TF_VAR_ad_managed_base_dn` | DN делегированной родительской OU |
| `TF_VAR_ad_user_passwords` | JSON-карта начальных или новых паролей по ключам `users.yaml` |

Повышение `password_version` запрашивает смену пароля Terraform. Передайте пароль для этой версии в `plan` и `apply`. Для записей под ротацией Vault используйте операции Vault.

### Vault

Задайте переменные с областью `vault/<ключ кластера>`.

| Переменная | Значение |
| --- | --- |
| `VAULT_CACERT` | PEM цепочки CA HTTPS API Vault, тип File |
| `VAULT_NAMESPACE` | Namespace Vault Enterprise, если используется |
| `TF_VAR_vault_ldap_url` | `ldaps://<AD_FQDN>:636` |
| `TF_VAR_vault_ldap_ca_file` | PEM цепочки CA AD, тип File |
| `TF_VAR_vault_ldap_auth_bind_dn`, `TF_VAR_vault_ldap_auth_bind_password` | DN и пароль учётки чтения LDAP auth |
| `TF_VAR_vault_ldap_auth_user_dn`, `TF_VAR_vault_ldap_auth_group_dn` | Базы поиска пользователей и групп |
| `TF_VAR_vault_ldap_secrets_bind_dn`, `TF_VAR_vault_ldap_secrets_bind_password` | DN и пароль отдельной учётки ротации |
| `TF_VAR_vault_ldap_secrets_user_dn` | База поиска сервисных учёток этого кластера |

Пометьте секреты `Protected` и `Masked/Hidden`. Передайте PEM типа File с проверкой TLS. JWT и роль для `plan` и `apply` выдаёт GitLab. При смене bind-пароля обновите переменную и увеличьте соответствующую версию в YAML.
