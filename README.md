# Terraform AD

GitLab CI/CD управляет OU, пользователями, группами и членством в Active Directory по YAML. Terraform настраивает LDAP-вход, политики и ротацию паролей в действующих кластерах Vault. Для AD и каждого Vault используется отдельный state GitLab.

В `main` включён инвентарь локального стенда `aed.adm`. Планы запускаются после включения соответствующего контура, применение подтверждается вручную. Ветка `Test` содержит стенд и mock-тесты.

[Развёртывание](docs/deployment.md) · [Исправление AD-провайдера](https://github.com/AnatolyED/terraform-provider-ad-ou-dacl)
