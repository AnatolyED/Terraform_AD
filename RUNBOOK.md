# Ручное развёртывание · main

Debian 12 amd64 запускает Runner, а GitLab, AD и Vault уже работают в корпоративном контуре.

Выполняйте блоки по порядку в одном Bash-сеансе и подставьте значения в угловых скобках.

## 1. Пакеты и образы

На чистой Debian установите зависимости и Docker из зеркала, а на полностью офлайн-хосте установите те же пакеты и зависимости через `sudo apt install /path/to/debs/*.deb`. [Docker Engine для Debian](https://docs.docker.com/engine/install/debian/)

```bash
sudo apt update
sudo apt install -y ca-certificates curl git jq openssl ldap-utils
sudo install -m 0755 -d /etc/apt/keyrings
mirror=https://mirror.yandex.ru/mirrors/download.docker.com/linux/debian
sudo curl -fsSL "$mirror/gpg" -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
printf 'deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] %s bookworm stable\n' "$mirror" |
  sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo systemctl enable --now docker
sudo docker compose version
```

Проверьте контрольные суммы и импортируйте образы из офлайн-комплекта.

```bash
bundle=/home/aed/terraform-ad-offline
(cd "$bundle" && sha256sum -c SHA256SUMS)
sudo docker load -i "$bundle/runner-images.tar"
git clone -b main "$bundle/Terraform_AD-debian12.bundle" /home/aed/Terraform_AD
cd /home/aed/Terraform_AD
```

## 2. Проект и инвентарь

Создайте пустой закрытый проект GitLab 18.6+, отправьте исходный код и защитите `main` после первого push.

```bash
gitlab_url='https://<GITLAB_FQDN>'
gitlab_ca='/path/to/gitlab-ca.pem'
project_id='<GITLAB_PROJECT_ID>'
branch=main
git remote add workgit "$gitlab_url/<GROUP>/<PROJECT>.git"
git -c http.sslCAInfo="$gitlab_ca" push -o ci.skip workgit HEAD:refs/heads/main
```

Добавьте реальные `ou.yaml`, `groups.yaml`, `users.yaml` в `inventory/active-directory/production/`, а кластеры — в `inventory/vault/clusters.yaml`. [Схема YAML](CONFIGURATION.md)

## 3. Runner

В **Settings → CI/CD → Runners** создайте два проектных Runner с тегами `terraform-docker` и `terraform-deploy`, выключите задания без тегов и защитите Runner с тегом `terraform-deploy`. [Регистрация Runner](https://docs.gitlab.com/runner/register/)

```bash
runner_network=bridge
runner_hosts=()
for kind in validate deploy; do
  name="terraform-ad-$project_id-$kind"
  config="/srv/gitlab-runner/$name"
  sudo install -m 0700 -d "$config"
  read -rsp "Runner token ($kind): " CI_SERVER_TOKEN
  printf '\n'
  export CI_SERVER_TOKEN
  sudo --preserve-env=CI_SERVER_TOKEN docker run --rm --network "$runner_network" \
    -e CI_SERVER_TOKEN -v "$config:/etc/gitlab-runner" -v "$gitlab_ca:/gitlab-ca.pem:ro" \
    terraform-ad/runner:19.5.1 register --non-interactive --url "$gitlab_url" \
    --name "$name" --executor docker --tls-ca-file /gitlab-ca.pem \
    --docker-image terraform-ad/terraform:1.17.1 --docker-helper-image terraform-ad/runner-helper:19.5.1 \
    --docker-pull-policy never --docker-network-mode "$runner_network" \
    --docker-volumes "$bundle/provider-mirror:/providers:ro" "${runner_hosts[@]}"
  unset CI_SERVER_TOKEN
  sudo docker run -d --name "$name" --restart unless-stopped --network "$runner_network" \
    -v "$config:/etc/gitlab-runner" -v "$gitlab_ca:/gitlab-ca.pem:ro" \
    -v /var/run/docker.sock:/var/run/docker.sock terraform-ad/runner:19.5.1
  sudo docker exec "$name" gitlab-runner verify
done
```

## 4. Active Directory

Делегируйте через `dsa.msc` права Terraform только в выделенной OU, выделите две отдельные bind-учётки Vault и ограничьте Reset Password сервисными учётками каждой роли.

```bash
ad_fqdn='<AD_FQDN>'
ad_ca='/path/to/ad-ca.pem'
openssl s_client -brief -connect "$ad_fqdn:636" -servername "$ad_fqdn" \
  -verify_hostname "$ad_fqdn" -verify_return_error -CAfile "$ad_ca" </dev/null
LDAPTLS_CACERT="$ad_ca" ldapwhoami -x -H "ldaps://$ad_fqdn:636" -D '<TERRAFORM_BIND_UPN>' -W
```

В **Settings → CI/CD → Variables** заполните переменные AD со scope `ad/production` и переменные каждого Vault со scope `vault/<ID>`, задав PEM как File, а пароли как Protected и Masked/Hidden. [Точные имена и форматы](CONFIGURATION.md#2-опции-запуска)

## 5. Vault и JWT

Повторите блок для каждого действующего Vault с операторским токеном и убедитесь, что существующий JWT mount и роли закреплены за вашим проектом. [GitLab ID tokens и Vault](https://docs.gitlab.com/ci/secrets/hashicorp_vault/)

```bash
vault_url='https://<VAULT_FQDN>:8200'
vault_ca='/path/to/vault-ca.pem'
vault_id=vault-01
vault_namespace=''
read -rsp 'Vault bootstrap token: ' vault_token
printf '\n'
vapi() {
  local method=$1 path=$2
  shift 2
  curl -fsS --cacert "$vault_ca" -X "$method" -H 'Content-Type: application/json' \
    -H "X-Vault-Namespace: $vault_namespace" -H @<(printf 'X-Vault-Token: %s\n' "$vault_token") \
    "$vault_url/v1/$path" "$@"
}
issuer=$(curl -fsS --cacert "$gitlab_ca" "$gitlab_url/.well-known/openid-configuration" | jq -er .issuer)
mount_type=$(vapi GET sys/auth | jq -r '(.data // .)["gitlab-jwt/"].type // ""')
if [[ -z $mount_type ]]; then
  vapi POST sys/auth/gitlab-jwt --data '{"type":"jwt"}'
else
  [[ $mount_type == jwt ]] &&
    vapi GET auth/gitlab-jwt/config | jq -e --arg issuer "$issuer" '.data.bound_issuer == $issuer' ||
    exit 1
fi
jq -nc --arg url "$gitlab_url" --arg issuer "$issuer" --rawfile ca "$gitlab_ca" \
  '{oidc_discovery_url:$url,bound_issuer:$issuer,oidc_discovery_ca_pem:$ca}' |
  vapi POST auth/gitlab-jwt/config --data-binary @-
for phase in plan apply; do
  action=verify; policies='["terraform-ad-plan"]'
  if [[ $phase == apply ]]; then action=start; policies='["terraform-ad-plan","terraform-ad-apply"]'; fi
  if existing=$(vapi GET "auth/gitlab-jwt/role/terraform-$phase" 2>/dev/null); then
    jq -e --arg project "$project_id" --arg env "vault/$vault_id" \
      '.data.bound_claims | .project_id == $project and .environment == $env' <<<"$existing" >/dev/null || exit 1
  fi
  jq -nc --rawfile policy "config/vault/terraform-$phase.hcl" '{policy:$policy}' |
    vapi PUT "sys/policies/acl/terraform-ad-$phase" --data-binary @-
  jq -nc --arg aud "$gitlab_url/terraform/vault/$phase" --arg project "$project_id" \
    --arg branch "$branch" --arg env "vault/$vault_id" --arg action "$action" --argjson policies "$policies" \
    '{role_type:"jwt",user_claim:"sub",bound_audiences:[$aud],bound_claims:{project_id:$project,ref_type:"branch",ref:$branch,ref_protected:"true",environment:$env,environment_action:$action},token_policies:$policies,token_explicit_max_ttl:900}' |
    vapi POST "auth/gitlab-jwt/role/terraform-$phase" --data-binary @-
done
unset vault_token
```

## 6. State, план и применение

Включите GitLab-managed state, сохраните резервную копию существующего state и перед первым планом импортируйте уже управляемые объекты AD и Vault в соответствующие state. [Команды импорта AD](DEPLOYMENT.md#3-gitlab-state-и-импорт-ad) · [Команды импорта Vault](DEPLOYMENT.md#4-действующие-vault)

Для ручного импорта откройте Terraform CLI с тем же зеркалом и подставьте доступные из контейнера пути к CA.

```bash
sudo docker run --rm -it --pull never --entrypoint /bin/sh \
  -v "$PWD:/project" -v "$bundle/provider-mirror:/providers:ro" \
  -v "$(dirname "$gitlab_ca"):/certs:ro" -w /project terraform-ad/terraform:1.17.1
```

Включите `AD_DEPLOY_ENABLED=true`, задайте `AD_DEPLOY_ENVIRONMENT=production` и выберите `VAULT_DEPLOY_MODE=single` с `VAULT_TARGET_ID=vault-01` для первого Vault или `all` для всей матрицы.

```bash
git add -- inventory/
git commit -m 'Configure AD and Vault inventory'
git -c http.sslCAInfo="$gitlab_ca" push -u workgit HEAD:refs/heads/configure-inventory
```

Создайте merge request и после merge проверьте сохранённые планы, затем запустите вручную `ad:apply` и `vault:apply` по выбранным кластерам.

## 7. Приёмка

Войдите в каждый Vault тестовым читателем и проверьте ожидаемую политику.

```bash
reader='<AD_SAM_ACCOUNT_NAME>'
read -rsp 'LDAP password: ' reader_password
printf '\n'
printf '%s' "$reader_password" | jq -Rsc '{password:.}' |
  curl -fsS --cacert "$vault_ca" -H 'Content-Type: application/json' --data-binary @- \
    "$vault_url/v1/auth/ad-ldap/login/$reader" |
  jq -e --arg policy 'ad-<POLICY_KEY>' '.auth.policies | index($policy) != null'
unset reader_password
```

Для каждой роли проверьте вход в AD с новым паролем после ротации и повторный план `No changes` для `ad-production` и каждого `vault-<ID>`.
