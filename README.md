# Terraform AD

GitLab CI/CD управляет объектами Active Directory из `data/active-directory/production/` и настройками действующих Vault из `data/vault/clusters.yaml`.

Пайплайн хранит отдельный state для AD и каждого Vault. Планы включаются переменными GitLab, применение запускается вручную.

[Инструкция](Инструкция.md)
