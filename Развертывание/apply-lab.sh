#!/usr/bin/env bash
set -euo pipefail
umask 077

directory=$(cd -- "$(dirname -- "$0")" && pwd)
runtime=${1:-"$directory/.lab"}
port=$(sed -n 's/^LAB_GITLAB_PORT=//p' "$runtime/compose.env")
host=$(sed -n 's/^LAB_GITLAB_ACCESS_HOST=//p' "$runtime/compose.env")
token=$(cat -- "$runtime/gitlab-token")
project=$(cat -- "$runtime/project-id")
pipeline=$(cat -- "$runtime/pipeline-id")
url="https://${host:-localhost}:$port/api/v4/projects/$project"
mkdir -p "$runtime/traces"

api() {
  local method=$1 path=$2
  curl -fsS --max-time 25 --cacert "$runtime/tls/gitlab-ca.pem" \
    --header "PRIVATE-TOKEN: $token" --request "$method" "$url/$path"
}
review_apply() {
  local plan=$1 apply=$2 plan_id apply_id
  plan_id=$(jq -r --arg name "$plan" '.[] | select(.name == $name and .status == "success") | .id' <<< "$jobs")
  apply_id=$(jq -r --arg name "$apply" '.[] | select(.name == $name and .status == "manual") | .id' <<< "$jobs")
  [[ -n $plan_id && -n $apply_id ]] || return 0
  api GET "jobs/$plan_id/trace" > "$runtime/traces/$plan_id.txt"
  grep -Eq 'Plan: [0-9]+ to add, [0-9]+ to change, 0 to destroy\.|No changes\.' "$runtime/traces/$plan_id.txt"
  api POST "jobs/$apply_id/play" >/dev/null
  printf 'Started %s from plan %s\n' "$apply" "$plan_id"
}

for attempt in $(seq 1 120); do
  jobs=$(api GET "pipelines/$pipeline/jobs?per_page=100")
  if jq -e 'any(.[]; .status == "failed" or .status == "canceled")' <<< "$jobs" >/dev/null; then
    while read -r id; do
      api GET "jobs/$id/trace" > "$runtime/traces/$id.txt"
    done < <(jq -r '.[] | select(.status == "failed" or .status == "canceled") | .id' <<< "$jobs")
    printf 'Lab pipeline failed. See %s/traces.\n' "$runtime" >&2
    exit 1
  fi
  if jq -e 'length == 14 and all(.[]; .status == "success")' <<< "$jobs" >/dev/null; then
    jq '[.[] | {id,name,stage,status}]' <<< "$jobs" > "$runtime/jobs.json"
    printf 'Pipeline %s passed all 14 jobs.\n' "$pipeline"
    exit 0
  fi
  review_apply 'ad:plan' 'ad:apply'
  if jq -e 'any(.[]; .name == "ad:apply" and .status == "success")' <<< "$jobs" >/dev/null; then
    for suffix in 01 02 03 04 05; do
      review_apply "vault:plan: [vault-$suffix]" "vault:apply: [vault-$suffix]"
    done
  fi
  sleep 4
done
printf 'Timed out waiting for pipeline %s.\n' "$pipeline" >&2
exit 1
