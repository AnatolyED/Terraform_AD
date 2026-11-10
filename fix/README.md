# Исправление чтения защиты OU

Официальные `isometry/ad` 0.5.0 и 0.6.0 воспроизвели сбой при создании защищённой OU под делегированной учёткой. Провайдер запрашивал security descriptor без флага DACL и возвращал `protected=false`. Патч на базе 0.6.0 добавляет DACL control к запросам чтения OU и содержит регрессионный тест.

## Проверенная сборка

- Исходный тег `v0.6.0`, commit `59358d7159fae9021080cb6fde0686a1c91e2d79`.
- Версия пакета `0.6.0-ou-dacl.lab.1` для `linux_amd64`.
- Архив `terraform-provider-ad_0.6.0-ou-dacl.lab.1_linux_amd64.zip`.
- SHA-256 `2d28f3e9ec4a6a7c65ee42ffd001bf7f2df56e454d38e72590fb9f32b8f67076`.
- [Патч](isometry-ad-v0.6.0-ou-dacl.patch) и [lock-файл пакета](ad-provider.lock.hcl).

## Внедрение в отдельной ветке

1. Возьмите проверенный ZIP из согласованного хранилища. Сверьте SHA-256. В `infra/active-directory/versions.tf` и `modules/active-directory/versions.tf` укажите точную версию `0.6.0-ou-dacl.lab.1`. Замените `infra/active-directory/.terraform.lock.hcl` файлом `ad-provider.lock.hcl`.
2. Поместите ZIP во внутреннее зеркало по пути `registry.terraform.io/isometry/ad/terraform-provider-ad_0.6.0-ou-dacl.lab.1_linux_amd64.zip`. Подключите зеркало к Runner, например как `/providers`. Задайте GitLab File-переменную `TF_CLI_CONFIG_FILE` со следующим содержимым.

```hcl
disable_checkpoint = true

provider_installation {
  filesystem_mirror {
    path = "/providers"
    include = ["registry.terraform.io/isometry/ad"]
  }
  network_mirror {
    url = "https://terraform-mirror.yandexcloud.net/"
    include = ["registry.terraform.io/hashicorp/vault"]
  }
}
```

3. Выполните `init -lockfile=readonly`. На делегированной тестовой ветке проверьте создание защищённой OU, отказ в прямом удалении и повторный `plan` без изменений. На копии рабочего state проверьте обновление OU на месте. Право `Delete Child` на родителе и `Delete Tree` на предках должно быть ограничено независимо от версии провайдера.

## Сборка нового пакета

В Linux с Go из `go.mod`, Terraform 1.17.1, Git и `zip` подготовьте отдельную рабочую папку. Укажите абсолютный путь к файлу патча. Для новой сборки используйте новый суффикс версии.

```sh
git clone --branch v0.6.0 --depth 1 https://github.com/isometry/terraform-provider-ad.git
cd terraform-provider-ad
test "$(git rev-parse HEAD)" = 59358d7159fae9021080cb6fde0686a1c91e2d79
git apply '<ABSOLUTE_PATCH_PATH>'
TF_ACC_TERRAFORM_PATH="$(command -v terraform)" go test ./...
version=0.6.0-ou-dacl.lab.2
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath \
  -ldflags "-X main.version=$version" -o "terraform-provider-ad_v$version" .
chmod 0755 "terraform-provider-ad_v$version"
zip -X "terraform-provider-ad_${version}_linux_amd64.zip" "terraform-provider-ad_v$version"
sha256sum "terraform-provider-ad_${version}_linux_amd64.zip"
```

После публикации новой версии обновите оба ограничения и сформируйте новый lock-файл командой `terraform -chdir=infra/active-directory providers lock -fs-mirror=<MIRROR_PATH> -platform=linux_amd64`. Если модули ещё не установлены, выполните `terraform -chdir=infra/active-directory get`. Lock-файл проверенной `lab.1` предназначен для указанного выше архива.
