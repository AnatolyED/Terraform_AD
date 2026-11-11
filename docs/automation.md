# Автоматизация Runner · main

Подготовьте [Debian и офлайн-комплект](deployment.md#1-пакеты-и-образы), затем создайте два [проектных Runner](platform.md#регистрация-runner).

## Параметры

Создайте локальный файл `runner.local.env` и замените адреса и пути.

```bash
OFFLINE_BUNDLE=/home/aed/terraform-ad-offline
GITLAB_URL='https://<GITLAB_FQDN>'
GITLAB_CA_FILE=/path/to/gitlab-ca.pem
GITLAB_PROJECT_ID='<GITLAB_PROJECT_ID>'
AD_HOST='<AD_FQDN>'
AD_CA_FILE=/path/to/ad-ca.pem
AD_MANAGED_BASE_DN='OU=TerraformADM,DC=adm,DC=example'
RUNNER_KIND=validate
VAULT_ENDPOINTS=('https://<VAULT_FQDN>:8200|/path/to/vault-ca.pem')
```

При необходимости задайте `AD_PORT`, `AD_CONNECT_IP`, `RUNNER_STATE_ROOT`, `RUNNER_JOB_NETWORK` и массив `RUNNER_EXTRA_HOSTS` со строками `имя:IP`.

## Запуск

Выполните команды с доступом к Docker для `RUNNER_KIND=validate` и `RUNNER_KIND=deploy`, вводя отдельный токен регистрации для каждого Runner.

```bash
bash deploy/install-runner.sh --check runner.local.env
bash deploy/install-runner.sh --install runner.local.env
```
