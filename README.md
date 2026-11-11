# Terraform_AD · Test

Стенд ADM использует Windows Server 2022, две Debian 12 VM и один Vault.

Тестовые YAML находятся в `data/`, mock-тесты в `infra/`, скрипты в `deploy/test/`.

- [Ручное развёртывание](docs/deployment.md) · порядок действий и команды.
- [Автоматизация](docs/automation.md) · запуск подготовленных скриптов.
- [Схема YAML и переменные](docs/configuration.md) · структура данных и настройки CI.
- [State и сопровождение](docs/operations.md) · импорт, обновление и восстановление.
- [Сборка AD-провайдера](docs/provider.md) · патч DACL и офлайн-пакет.
