# Сборка AD-провайдера

Сборка `0.6.0-ou-dacl.1` основана на теге `v0.6.0`, commit `59358d7159fae9021080cb6fde0686a1c91e2d79`. [Патч](../fix/isometry-ad-v0.6.0-ou-dacl.patch) запрашивает DACL при чтении защищённых OU и содержит регрессионный тест.

```sh
git clone --branch v0.6.0 --depth 1 https://github.com/isometry/terraform-provider-ad.git
cd terraform-provider-ad
test "$(git rev-parse HEAD)" = 59358d7159fae9021080cb6fde0686a1c91e2d79
git apply --check '<ABSOLUTE_PATCH_PATH>'
git apply '<ABSOLUTE_PATCH_PATH>'
go test ./internal/ldap ./internal/provider -run 'Test.*(OU|DACL|SecurityDescriptor)' -count=1
version=0.6.0-ou-dacl.1
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath \
  -ldflags "-X main.version=$version" -o "terraform-provider-ad_v$version" .
chmod 0755 "terraform-provider-ad_v$version"
zip -X "terraform-provider-ad_${version}_linux_amd64.zip" "terraform-provider-ad_v$version"
sha256sum "terraform-provider-ad_${version}_linux_amd64.zip"
```

SHA-256 ZIP поставки — `a4cfc6b83cb6ac779ae536e4078128875d3dc38d2c413791903155357a8ca515`. Поместите ZIP в `provider-mirror/registry.terraform.io/isometry/ad/`. Для другой сборки выпустите новую версию, обновите оба ограничения версии и пересчитайте lock-файл из зеркала.
