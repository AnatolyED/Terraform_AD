# Автоматизация стенда ADM

Подготовьте [зависимости, офлайн-образы и сеть](deployment.md#2-debian-и-офлайн-образы) на отдельных тестовых VM.

## 1. AD DS

На выделенной VM задайте имя контроллера и закрепите IPv4. В PowerShell от администратора запустите из папки скриптов:

```powershell
.\Initialize-WindowsAd.ps1 -Phase Forest -Check
.\Initialize-WindowsAd.ps1 -Phase Forest
```

После перезагрузки войдите администратором тестового домена и укажите фактические исходящие IP двух Debian VM, которые увидит Windows Firewall:

```powershell
.\Initialize-WindowsAd.ps1 -Phase Directory -DebianIp '<TERRAFORM_IPV4>','<VAULT_IPV4>' -Check
.\Initialize-WindowsAd.ps1 -Phase Directory -DebianIp '<TERRAFORM_IPV4>','<VAULT_IPV4>'
```

Запомните пароли `svc-terraform`, `svc-auth`, `svc-rotation`. Перенесите публичный `C:\TerraformAD\ad-ca.pem` на Debian с Terraform и перезагрузите DC. По умолчанию скрипт создаёт `adm.example` и `OU=TerraformADM`. Для другого тестового домена передайте одинаковый `-AdmDomain` в обе фазы и согласуйте DN в файле параметров.

## 2. Параметры Debian

Клонируйте ветку Test по [шагу подготовки Debian](deployment.md#2-debian-и-офлайн-образы).

На каждой VM создайте `adm.local.env`. Подставьте фактические адреса и пути. `ADM_GITLAB_BIND_IP` и `ADM_VAULT_BIND_IP` — адреса интерфейсов соответствующих VM. У обоих хостов должны быть одинаковые FQDN, порты и параметры AD.

```bash
OFFLINE_BUNDLE=/home/aed/terraform-ad-offline
ADM_RUNTIME=/home/aed/terraform-ad-runtime
ADM_AD_HOST='<AD_FQDN>'
ADM_AD_IP='<AD_IPV4>'
ADM_AD_CA_FILE=/home/aed/ad-ca.pem
ADM_AD_DOMAIN=adm.example
ADM_AD_MANAGED_BASE_DN='OU=TerraformADM,DC=adm,DC=example'
ADM_ACCOUNT_PREFIX=adm
ADM_GITLAB_HOST='<GITLAB_FQDN>'
ADM_GITLAB_BIND_IP='<TERRAFORM_IPV4>'
ADM_GITLAB_PORT=8929
ADM_VAULT_HOST='<VAULT_FQDN>'
ADM_VAULT_BIND_IP='<VAULT_IPV4>'
ADM_VAULT_PORT=8200
```

Если используете ранее заполненный тестовый лес, задайте свободный `ADM_ACCOUNT_PREFIX` до первого запуска проекта. Он меняет имена пользователей и групп в AD, сохраняя ключи YAML.

## 3. Сертификаты и Vault

На Debian с Terraform сгенерируйте сертификаты.

```bash
bash deploy/test/start.sh --check terraform adm.local.env
bash deploy/test/start.sh --tls terraform adm.local.env
```

Передайте `tls/adm-ca.pem`, `tls/vault.pem` и `tls/vault.key` на Vault VM в `$ADM_RUNTIME/tls/` по защищённому каналу. Права файла `vault.key` задайте `0600`. На Vault VM запустите:

```bash
bash deploy/test/start.sh --check vault adm.local.env
bash deploy/test/start.sh --start vault adm.local.env
```

Скрипт создаёт и распечатывает тестовый Vault. Ключ распечатывания и начальный токен хранятся в `$ADM_RUNTIME/vault-init.json` с ограниченными правами. На Debian с Terraform следующий скрипт запросит только поле `root_token` и три пароля AD. Если обе роли работают на одной машине и используют общий `ADM_RUNTIME`, токен читается локально.

## 4. GitLab и проверка

Для приёмки `main` укажите источник, а для обычного запуска `Test` используйте параметры по умолчанию.

```bash
ADM_PROJECT_PATH=terraform-ad-main-check
ADM_GIT_BRANCH=main
ADM_SOURCE_REPO=/home/aed/terraform-ad-offline/Terraform_AD-debian12.bundle
ADM_SOURCE_REF=refs/heads/main
```

Используйте отдельный Vault для каждого тестового GitLab-проекта.

```bash
bash deploy/test/start.sh --start terraform adm.local.env
bash deploy/test/apply.sh adm.local.env
bash deploy/test/verify.sh adm.local.env
```

Скрипты регистрируют Runner, проверяют план перед применением и проверяют LDAP, ротацию и state.

Для входа в GitLab используйте его начальный пароль из [инструкции](deployment.md#3-tls-gitlab-и-vault) и доверьте браузеру публичный CA ADM.
