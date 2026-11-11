# Общие команды

## Зависимости Debian

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

## Регистрация Runner

В **Settings → CI/CD → Runners** создайте два проектных Runner с тегами `terraform-docker` и `terraform-deploy`, выключите задания без тегов и защитите Runner с тегом `terraform-deploy`. [Регистрация Runner](https://docs.gitlab.com/runner/register/)

```bash
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

## JWT для Vault

Для каждого Vault проверьте доступ к OIDC GitLab и используйте операторский токен.

```bash
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
