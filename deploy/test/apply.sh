#!/usr/bin/env bash
set -euo pipefail
umask 077

directory=$(cd -- "$(dirname -- "$0")" && pwd)
source "$(realpath -- "$1")"
runtime=$(realpath -m -- "${ADM_RUNTIME:-$directory/.adm}")
project_runtime="$runtime/${ADM_PROJECT_PATH:-terraform-ad-adm}"
project=$(cat "$project_runtime/project-id")
pipeline=$(cat "$project_runtime/pipeline-id")
token=$(cat "$project_runtime/gitlab-token")
url="https://$ADM_GITLAB_HOST:${ADM_GITLAB_PORT:-8929}/api/v4/projects/$project"
mkdir -p "$project_runtime/traces"
api() {
  curl -fsS --max-time 25 --cacert "$runtime/tls/adm-ca.pem" -H "PRIVATE-TOKEN: $token" -X "$1" "$url/$2"
}
apply() {
  local plan=$1 job=$2 plan_id job_id
  plan_id=$(jq -r --arg name "$plan" '.[] | select(.name == $name and .status == "success") | .id' <<< "$jobs")
  job_id=$(jq -r --arg name "$job" '.[] | select(.name == $name and .status == "manual") | .id' <<< "$jobs")
  [[ -n $plan_id && -n $job_id ]] || return 0
  api GET "jobs/$plan_id/trace" > "$project_runtime/traces/$plan_id.txt"
  grep -Eq 'Plan: [0-9]+ to add, [0-9]+ to change, 0 to destroy\.|No changes\.' "$project_runtime/traces/$plan_id.txt"
  api POST "jobs/$job_id/play" >/dev/null
  printf 'Started %s from plan %s\n' "$job" "$plan_id"
}
for attempt in $(seq 1 120); do
  jobs=$(api GET "pipelines/$pipeline/jobs?per_page=100")
  if jq -e 'any(.[]; .status == "failed" or .status == "canceled")' <<< "$jobs" >/dev/null; then
    while read -r id; do api GET "jobs/$id/trace" > "$project_runtime/traces/$id.txt"; done < <(
      jq -r '.[] | select(.status == "failed" or .status == "canceled") | .id' <<< "$jobs"
    )
    printf 'Pipeline %s failed. Traces: %s/traces\n' "$pipeline" "$project_runtime" >&2
    exit 1
  fi
  if jq -e '(length == 6 or length == 8) and all(.[]; .status == "success")' <<< "$jobs" >/dev/null; then
    jq '[.[] | {id,name,status}]' <<< "$jobs" > "$project_runtime/jobs.json"
    printf 'Pipeline %s passed %s jobs\n' "$pipeline" "$(jq length <<< "$jobs")"
    exit 0
  fi
  apply ad:plan ad:apply
  if jq -e 'any(.[]; .name == "ad:apply" and .status == "success")' <<< "$jobs" >/dev/null; then
    apply 'vault:plan: [vault-01]' 'vault:apply: [vault-01]'
  fi
  sleep 4
done
printf 'Timed out waiting for pipeline %s\n' "$pipeline" >&2
exit 1
