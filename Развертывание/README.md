# Локальный стенд на Debian 13

GitLab CE, Runner и пять Vault запускаются в Docker Compose. Контроллер AD DS работает в Windows Server VM. Можно подключить уже доступный тестовый Windows AD DS. Vault работает в dev-режиме с TLS. GitLab слушает только `127.0.0.1`. Стенд использует отдельный домен и тестовые учётки.

## 1. Подготовка файлов без Docker Hub на рабочей машине

На машине с доступом к разрешённым источникам клонируйте `Test` и подготовьте пакет. Для Bash-скриптов нужны `curl`, `jq`, `openssl`, `git`, `tar` и `coreutils`. Для Windows VM понадобятся KVM, libvirt, virt-install и OVMF. На Debian пакеты можно брать из [зеркала Яндекса](https://mirror.yandex.ru/debian/) для `trixie`.

```sh
git switch Test
bash 'Развертывание/prepare-bundle.sh' '<PATH_TO_VERIFIED_AD_ZIP>' '<OUTPUT_DIRECTORY>'
git bundle create Terraform_AD-Test.bundle Test
```

Имя и SHA-256 AD-архива указаны в [инструкции по патчу](../fix/README.md). Для Vault-архива скрипт сначала использует зеркало Terraform Яндекса. При необходимости передайте локальный `VAULT_PROVIDER_ZIP` или разрешите официальный источник через `ALLOW_ORIGIN=1`. OCI-образы берутся по закреплённым digest. При наличии корпоративного реестра передайте доступные ссылки через `GITLAB_IMAGE`, `RUNNER_IMAGE`, `HELPER_IMAGE`, `VAULT_IMAGE` и `TERRAFORM_IMAGE`. Прокси для загрузки образов задаётся у Docker daemon.

Перенесите `Terraform_AD-Test.bundle`, `images.tar`, `provider-mirror/` и `SHA256SUMS` в `/home/aed/terraform-ad-offline/` на Debian. Для переноса используйте разрешённый носитель или внутреннее хранилище. GitHub хранит код и документацию. Архивы образов и провайдеров распространяются отдельно.

```sh
git clone -b Test /home/aed/terraform-ad-offline/Terraform_AD-Test.bundle /home/aed/Terraform_AD
cd /home/aed/Terraform_AD
```

## 2. Windows AD DS

Для локальной VM используйте официальный Windows Server ISO, доступный по вашей лицензии. Требуется доступ к `/dev/kvm` и сети libvirt `default`. `create-windows-vm.sh` выделяет 4 ГБ RAM, 2 vCPU и 64 ГБ диска. Установка Windows выполняется в `virt-manager`.

```sh
bash 'Развертывание/create-windows-vm.sh' '<PATH_TO_WINDOWS_SERVER_ISO>'
```

В гостевой Windows Server перед настройкой домена закрепите IP или DHCP-резервацию. Убедитесь, что сервер имеет имя, которое вы будете использовать в LDAPS. Скопируйте `Initialize-WindowsAd.ps1` в VM и выполните из административного PowerShell.

```powershell
.\Initialize-WindowsAd.ps1 -Phase Forest
```

После перезагрузки войдите администратором тестового домена и выполните следующий шаг. Скрипт создаст выделенную OU, учётки и LDAPS-сертификат. Пароли вводятся через скрытый ввод.

```powershell
.\Initialize-WindowsAd.ps1 -Phase Directory
```

Перезагрузите VM для применения LDAPS-сертификата. Перенесите публичный `C:\TerraformLab\ad-ca.pem` на Debian. Проверьте доступность IP гостя на TCP 636 из Docker-сети. Для внешней тестовой Windows VM используйте её CA, FQDN, IP и согласованную выделенную OU с аналогичным делегированием. Windows AD DS поддерживается как роль Windows Server в VM. [Ограничения Windows-контейнеров](https://learn.microsoft.com/en-us/virtualization/windowscontainers/quick-start/lift-shift-to-containers)

## 3. Запуск GitLab, Runner и пяти Vault

```sh
export LAB_AD_HOST='<WINDOWS_DC_FQDN>'
export LAB_AD_IP='<WINDOWS_DC_IP>'
export LAB_AD_CA_FILE='/home/aed/ad-ca.pem'
bash 'Развертывание/start-lab.sh' '/home/aed/terraform-ad-offline'
```

Для домена, созданного скриптом, значения по умолчанию — `lab.example`, `OU=TerraformLab,DC=lab,DC=example` и учётки `svc-terraform`, `svc-auth`, `svc-rotation`. Для другой выделенной тестовой ветки задайте `LAB_AD_DOMAIN`, `LAB_AD_BASE_DN`, `LAB_AD_TF_UPN`, `LAB_AD_AUTH_DN` и `LAB_AD_ROTATION_DN`. Скрипт запросит три пароля bind-учёток. При занятом порте задайте `LAB_GITLAB_PORT`.

Скрипт проверяет LDAPS и целостность комплекта, импортирует образы, поднимает Compose без загрузки из сети, создаёт закрытый GitLab-проект, настраивает Runner и JWT-роли Vault. Отдельная копия проекта в `.lab/project` использует исправленный AD-пакет и локальное зеркало Runner. Скрипт генерирует пять пар пользователей и групп для теста и запускает pipeline. Пароли и конфигурация стенда сохраняются в игнорируемом каталоге `.lab` с ограниченными правами.

Для доступа к интерфейсу GitLab добавьте `127.0.0.1 gitlab.terraform.test` в `/etc/hosts` и добавьте `.lab/tls/gitlab-ca.pem` в доверенные сертификаты браузера. Откройте `https://gitlab.terraform.test:8929` с портом из `LAB_GITLAB_PORT`. Начальный пароль `root` доступен в контейнере GitLab в `/etc/gitlab/initial_root_password` после инициализации.

Проверьте планы в GitLab и подтвердите `apply`. Для изолированного стенда можно запустить подтверждения после машинной проверки планов без удалений.

```sh
bash 'Развертывание/apply-lab.sh'
```

Для автоматического запуска этого шага сразу после подготовки передайте `--apply` вторым аргументом `start-lab.sh`. В проверенном pipeline AD применяется первым. Каждый Vault получает сохранённый план своей строки матрицы.

## 4. Проверка и остановка

После завершения 14 заданий запустите проверку. Для неё нужен `ldapwhoami` из пакета `ldap-utils`. FQDN контроллера должен разрешаться на Debian. Скрипт проверяет LDAP-вход, политику, новый bind после ротации и отдельные state для всех пяти Vault. Интервал ротации — 60 секунд. См. [результаты запуска с офлайн-комплектом](../test-results/offline-lab.txt) и [журналы предыдущего прогона](../test-results/job-excerpts.txt).

```sh
bash 'Развертывание/verify-lab.sh'
docker compose --env-file 'Развертывание/.lab/compose.env' -f 'Развертывание/compose.yaml' ps
docker compose --env-file 'Развертывание/.lab/compose.env' -f 'Развертывание/compose.yaml' down
```

GitLab хранит данные в именованных томах. При пересоздании Vault dev теряет данные в памяти. Перед повторным запуском с пустыми Vault согласуйте сброс только тестовых state и объектов AD. Для запуска нового отдельного стенда нужен отдельный набор тестовых объектов и чистый локальный GitLab.
