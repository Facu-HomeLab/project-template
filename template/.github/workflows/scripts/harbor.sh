#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

harbor_api() {
  local method="$1" url="$2" user="$3" pass="$4" body="${5:-}"
  if [[ -n "$body" ]]; then
    curl --fail --silent --show-error -X "$method" -u "$user:$pass" \
      -H 'Content-Type: application/json' --data "$body" "$url"
  else
    curl --fail --silent --show-error -X "$method" -u "$user:$pass" "$url"
  fi
}
ensure_project() {
  local base="$1" project="$2" secret_file="$3" user pass status
  user="$(json_secret "$secret_file" HARBOR_ADMIN_USERNAME)"
  pass="$(json_secret "$secret_file" HARBOR_ADMIN_PASSWORD)"
  status="$(curl --silent --output /tmp/harbor-project-check.$$ --write-out '%{http_code}' \
    -u "$user:$pass" "${base%/}/api/v2.0/projects/$project")"
  case "$status" in
    200)
      jq -e '(.metadata.public | tostring) == "false"' \
        /tmp/harbor-project-check.$$ >/dev/null \
        || die "Harbor project '$project' exists but is public or has incompatible metadata"
      ;;
    404)
      harbor_api POST "${base%/}/api/v2.0/projects" "$user" "$pass" \
        "$(jq -n --arg name "$project" '{project_name:$name,public:false,metadata:{public:"false"}}')" >/dev/null
      ;;
    *) cat /tmp/harbor-project-check.$$ >&2 || true; rm -f /tmp/harbor-project-check.$$; die "Unexpected Harbor project lookup HTTP status: $status" ;;
  esac
  rm -f /tmp/harbor-project-check.$$
}
create_robot() {
  local base="$1" project="$2" secret_file="$3" run_id="$4" out_secret="$5" out_state="$6"
  local user pass body response
  user="$(json_secret "$secret_file" HARBOR_ADMIN_USERNAME)"
  pass="$(json_secret "$secret_file" HARBOR_ADMIN_PASSWORD)"
  body="$(jq -n --arg name "gha-${run_id}" --argjson duration 1 \
    '{name:$name,description:"Ephemeral GitHub Actions robot",duration:$duration,level:"project",permissions:[{kind:"project",namespace:"",access:[{resource:"repository",action:"pull"},{resource:"repository",action:"push"}]}]}')"
  # Harbor's robot permission namespace is the project name.
  body="$(jq --arg project "$project" '.permissions[0].namespace=$project' <<<"$body")"
  response="$(harbor_api POST "${base%/}/api/v2.0/robots" "$user" "$pass" "$body")"
  local robot_id robot_name robot_secret
  robot_id="$(jq -er '.id' <<<"$response")"
  robot_name="$(jq -er '.name' <<<"$response")"
  robot_secret="$(jq -er '.secret' <<<"$response")"
  umask 077
  printf '%s' "$robot_secret" > "$out_secret"; chmod 600 "$out_secret"
  jq -n --arg id "$robot_id" --arg name "$robot_name" '{id:$id,name:$name}' > "$out_state"; chmod 600 "$out_state"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'robot_id=%s\nrobot_name=%s\nrobot_secret_file=%s\nrobot_state_file=%s\n' "$robot_id" "$robot_name" "$out_secret" "$out_state" >> "$GITHUB_OUTPUT"
  fi
  echo "::add-mask::$robot_secret"
  unset robot_secret response
}
delete_robot() {
  local base="$1" secret_file="$2" state_file="$3" user pass id
  [[ -s "$state_file" ]] || return 0
  user="$(json_secret "$secret_file" HARBOR_ADMIN_USERNAME)"
  pass="$(json_secret "$secret_file" HARBOR_ADMIN_PASSWORD)"
  id="$(jq -er '.id' "$state_file")"
  curl --fail --silent --show-error -X DELETE -u "$user:$pass" "${base%/}/api/v2.0/robots/$id" >/dev/null
}
