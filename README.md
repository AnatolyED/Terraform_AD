# Terraform_AD

GitLab CI/CD управляет объектами Active Directory из YAML и настраивает LDAP-аутентификацию, политики доступа и ротацию сервисных паролей в Vault. Для AD и каждого Vault используется отдельный GitLab state.

Terraform 1.17.1 запускается в Linux-контейнере. Версии провайдеров — `isometry/ad` 0.5.0 и `hashicorp/vault` 5.13.0. Целевая версия Vault Server — 2.2.1. Изменения проходят `validate`, `plan` и подтверждаемый `apply` сохранённого плана.

Создание защищённых OU под делегированной учёткой требует исправления AD-провайдера. См. [описание исправления и порядок подключения](https://github.com/AnatolyED/Terraform_AD/tree/Test/fix).

- [Развёртывание и подключение к существующим AD и Vault](DEPLOYMENT.md)
- [Сущности и настройки](CONFIGURATION.md)

Ветка Test содержит локальный стенд для Debian 13, mock-тесты и отдельный патч AD-провайдера. [Инструкция по стенду](https://github.com/AnatolyED/Terraform_AD/tree/Test/Развертывание) · [Результаты проверок](https://github.com/AnatolyED/Terraform_AD/blob/Test/WORK-SUMMARY.md)
