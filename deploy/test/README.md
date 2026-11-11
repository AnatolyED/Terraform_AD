# Тестовый стенд на трёх VM

- Windows Server 2022 · отдельный AD DS и LDAPS.
- Debian 12 amd64 с Terraform · локальный GitLab, два Docker Runner и Terraform 1.17.1.
- Debian 12 amd64 с Vault · один Vault 2.2.1 с TLS и постоянным Raft-томом.

На Debian нужны Docker Engine, Compose, Bash, Git, `curl`, `jq`, `openssl` и `ldap-utils`. На Debian с Terraform перенесите комплект Runner, `gitlab-image.tar` и `GITLAB-SHA256SUMS`. На Vault VM перенесите `vault-image.tar` и `VAULT-SHA256SUMS`. Git bundle нужен на обеих VM. Откройте TCP 636 к AD с обеих Debian VM, порт GitLab с Vault и порт Vault с Terraform. Настройте разрешение имён GitLab и Vault также из Docker-контейнеров, а имени AD — на Debian с Terraform. Локальный GitLab 19.5.1 использует свой HTTPS endpoint для JWT.

## Windows Server 2022

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

Запомните пароли `svc-terraform`, `svc-auth`, `svc-rotation`. Перенесите публичный `C:\TerraformAD\ad-ca.pem` на Debian с Terraform и перезагрузите DC. По умолчанию скрипт создаёт `lab.example` и `OU=TerraformLab`. Для другого тестового домена передайте одинаковый `-LabDomain` в обе фазы и согласуйте DN в файле параметров.

## Debian 12

Клонируйте тестовую ветку из офлайн-комплекта на обе VM:

```bash
git clone -b Test /home/aed/terraform-ad-offline/Terraform_AD-debian12.bundle /home/aed/Terraform_AD
cd /home/aed/Terraform_AD
```

На каждой VM создайте `lab.local.env`. Подставьте фактические адреса и пути. `LAB_GITLAB_BIND_IP` и `LAB_VAULT_BIND_IP` — адреса интерфейсов соответствующих VM. У обоих хостов должны быть одинаковые FQDN, порты и параметры AD.

```bash
OFFLINE_BUNDLE=/home/aed/terraform-ad-offline
LAB_RUNTIME=/home/aed/terraform-ad-runtime
LAB_AD_HOST='<AD_FQDN>'
LAB_AD_IP='<AD_IPV4>'
LAB_AD_CA_FILE=/home/aed/ad-ca.pem
LAB_AD_DOMAIN=lab.example
LAB_AD_MANAGED_BASE_DN='OU=TerraformLab,DC=lab,DC=example'
LAB_ACCOUNT_PREFIX=lab
LAB_GITLAB_HOST='<GITLAB_FQDN>'
LAB_GITLAB_BIND_IP='<TERRAFORM_IPV4>'
LAB_GITLAB_PORT=8929
LAB_VAULT_HOST='<VAULT_FQDN>'
LAB_VAULT_BIND_IP='<VAULT_IPV4>'
LAB_VAULT_PORT=8200
```

Если используете ранее заполненный тестовый лес, задайте свободный `LAB_ACCOUNT_PREFIX` до первого запуска проекта. Он меняет имена пользователей и групп в AD, сохраняя ключи YAML.

На Debian с Terraform сгенерируйте сертификаты:

```bash
bash deploy/test/start.sh --check terraform lab.local.env
bash deploy/test/start.sh --tls terraform lab.local.env
```

Передайте `tls/lab-ca.pem`, `tls/vault.pem` и `tls/vault.key` на Vault VM в `$LAB_RUNTIME/tls/` по защищённому каналу. Права файла `vault.key` задайте `0600`. На Vault VM запустите:

```bash
bash deploy/test/start.sh --check vault lab.local.env
bash deploy/test/start.sh --start vault lab.local.env
```

Скрипт создаёт и распечатывает тестовый Vault. Ключ распечатывания и начальный токен хранятся в `$LAB_RUNTIME/vault-init.json` с ограниченными правами. На Debian с Terraform следующий скрипт запросит только поле `root_token` и три пароля AD. Если обе роли работают на одной машине и используют общий `LAB_RUNTIME`, токен читается локально.

Для приёмки кандидата `main` добавьте в `lab.local.env` на Debian с Terraform:

```bash
LAB_PROJECT_PATH=terraform-ad-main-check
LAB_GIT_BRANCH=main
LAB_SOURCE_REPO=/home/aed/terraform-ad-offline/Terraform_AD-debian12.bundle
LAB_SOURCE_REF=refs/heads/main
```

При обычном запуске `Test` параметры выше не нужны. Один тестовый Vault закрепляется за одним GitLab-проектом. Для нового проекта потребуется новый тестовый экземпляр или согласованный сброс тестового Raft-тома.

```bash
bash deploy/test/start.sh --start terraform lab.local.env
bash deploy/test/apply.sh lab.local.env
bash deploy/test/verify.sh lab.local.env
```

Скрипт старта создаёт закрытый проект, регистрирует два Runner, подключает Vault JWT и печатает SHA исходного коммита и URL pipeline. Кандидат `main` получает шесть заданий, `Test` добавляет два задания с mock-тестами. `apply.sh` запускает применение только после плана с нулём удалений. `verify.sh` проверяет LDAP-доступ и отказ постороннему пользователю, защиту одноразовой OU от удаления, ротацию, раздельный state и повторный план без изменений.

GitLab хранит bootstrap-токен и результаты в `$LAB_RUNTIME/<путь-проекта>/`. Для просмотра pipeline доверьте браузеру `tls/lab-ca.pem`. Первичный пароль локального GitLab находится в контейнере по пути `/etc/gitlab/initial_root_password`. Для диагностики повторный запуск `start.sh` использует существующие проект, Vault и Runner, если параметры совпадают.
