#!/usr/bin/env bash

# Start GitLab CE and GitLab Runner in Docker, then prove a CI pipeline can run green.

set -Eeuo pipefail
IFS=$'\n\t'

usage() {
  cat <<'EOF'
Run a local GitLab with a Runner that executes CI jobs in Docker.

Usage:
  gitlab-ci.sh [command] [options]

Commands:
  up        Start the stack, register the runner, push a demo project and wait for
             its pipeline to succeed. Default command.
  status    Show container, runner and latest pipeline state.
  down      Stop the containers. Config, data and logs are kept.

Options (environment variables work as well):
  --dir PATH              Directory holding config/logs/data/runner-config.
                           Defaults to $HOME/gitlab-docker.
  --host NAME             Hostname GitLab is reached by. Defaults to
                           gitlab.127.0.0.1.nip.io, a public wildcard DNS name that
                           resolves to 127.0.0.1, so the browser, the runner and the CI
                           job containers all agree without an /etc/hosts entry.
                           See README.md for a hosts-file based alternative.
  --port PORT             Published HTTP port. Defaults to 8929.
  --ssh-port PORT         Published git-over-SSH port. Defaults to 2224.
  --network NAME          Docker network shared with build containers. Defaults to gitlab-net.
  --tag LIST              Runner tags. Defaults to "mac".
  --project NAME          Demo project name. Defaults to ci-demo.
  --namespace NAME        Demo project namespace. Defaults to root.
  --ready-timeout SECONDS Wait budget for GitLab to boot. Defaults to 900.
  --pipeline-timeout SECONDS Wait budget for the pipeline. Defaults to 600.
  -h, --help              Show this help.

Requirements: docker with compose plugin, git, curl, python3, openssl.

The script writes only into --dir. It never deletes data: it keeps an existing online
runner instead of registering a duplicate, stores the API token it mints as
<dir>/dev-env-token (mode 600), and re-triggers a pipeline that ended in failure
instead of re-reporting it.
EOF
}

log() {
  printf '%s\n' "$*"
}

step() {
  printf '\n==> %s\n' "$*"
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_value() {
  local option_name=$1
  local option_value=${2:-}
  [[ -n "$option_value" ]] || die "$option_name requires a value"
}

json_field() {
  python3 -c 'import json, sys
try:
    data = json.load(sys.stdin)
except ValueError:
    sys.exit(1)
value = data.get(sys.argv[1]) if isinstance(data, dict) else None
if value is not None:
    print(value)' "$1"
}

json_first() {
  python3 -c 'import json, sys
try:
    data = json.load(sys.stdin)
except ValueError:
    sys.exit(1)
if isinstance(data, list) and data:
    print(data[0].get(sys.argv[1], ""))' "$1"
}

urlencode() {
  python3 -c 'import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

looks_like_user_json() {
  python3 -c 'import json, sys
data = json.load(sys.stdin)
sys.exit(0 if isinstance(data, dict) and data.get("id") else 1)' 2>/dev/null
}

GITLAB_DIR="${GITLAB_DIR:-$HOME/gitlab-docker}"
GITLAB_HOST="${GITLAB_HOST:-gitlab.127.0.0.1.nip.io}"
GITLAB_PORT="${GITLAB_PORT:-8929}"
GITLAB_SSH_PORT="${GITLAB_SSH_PORT:-2224}"
GITLAB_NETWORK="${GITLAB_NETWORK:-gitlab-net}"
RUNNER_TAG="${RUNNER_TAG:-mac}"
RUNNER_DESCRIPTION="${RUNNER_DESCRIPTION:-dev-env-runner}"
DEMO_PROJECT="${DEMO_PROJECT:-ci-demo}"
DEMO_NAMESPACE="${DEMO_NAMESPACE:-root}"
READY_TIMEOUT="${READY_TIMEOUT:-900}"
PIPELINE_TIMEOUT="${PIPELINE_TIMEOUT:-600}"

COMMAND="up"

while [[ $# -gt 0 ]]; do
  case "$1" in
    up | status | down)
      COMMAND=$1
      ;;
    --dir)
      require_value "$1" "${2:-}"
      GITLAB_DIR=$2
      shift
      ;;
    --host)
      require_value "$1" "${2:-}"
      GITLAB_HOST=$2
      shift
      ;;
    --port)
      require_value "$1" "${2:-}"
      GITLAB_PORT=$2
      shift
      ;;
    --ssh-port)
      require_value "$1" "${2:-}"
      GITLAB_SSH_PORT=$2
      shift
      ;;
    --network)
      require_value "$1" "${2:-}"
      GITLAB_NETWORK=$2
      shift
      ;;
    --tag)
      require_value "$1" "${2:-}"
      RUNNER_TAG=$2
      shift
      ;;
    --project)
      require_value "$1" "${2:-}"
      DEMO_PROJECT=$2
      shift
      ;;
    --namespace)
      require_value "$1" "${2:-}"
      DEMO_NAMESPACE=$2
      shift
      ;;
    --ready-timeout)
      require_value "$1" "${2:-}"
      READY_TIMEOUT=$2
      shift
      ;;
    --pipeline-timeout)
      require_value "$1" "${2:-}"
      PIPELINE_TIMEOUT=$2
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown argument: $1"
      ;;
  esac
  shift
done

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
GITLAB_URL="http://${GITLAB_HOST}:${GITLAB_PORT}"
API_URL="${GITLAB_URL}/api/v4"
PROJECT_PATH="${DEMO_NAMESPACE}/${DEMO_PROJECT}"
PROJECT_URL="${GITLAB_URL}/${PROJECT_PATH}"
PROJECT_ID=""
RUNNER_SUMMARY=""
TOKEN_FILE="${GITLAB_DIR}/dev-env-token"
TOKEN=""

export GITLAB_DIR GITLAB_HOST GITLAB_PORT GITLAB_SSH_PORT GITLAB_NETWORK

compose() {
  docker compose -f "$COMPOSE_FILE" "$@"
}

api() {
  local method=$1
  local path=$2
  local body=${3:-}
  local args=(-s -X "$method" -H "PRIVATE-TOKEN: ${TOKEN}" --max-time 30)
  if [[ -n "$body" ]]; then
    args+=(-H 'Content-Type: application/json' --data "$body")
  fi
  curl "${args[@]}" "${API_URL}${path}"
}

# GitLab answers 401 for the API as soon as Rails is serving, which is exactly the
# readiness signal wanted here; a 502 means nginx is up but Rails is still booting.
gitlab_is_serving() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${API_URL}/projects?per_page=1" || true)
  [[ "$code" == "401" || "$code" == "200" ]]
}

container_health() {
  docker inspect -f '{{.State.Status}}/{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$1" 2>/dev/null || echo "absent"
}

preflight() {
  require_command docker
  require_command git
  require_command curl
  require_command python3
  require_command openssl

  docker info >/dev/null 2>&1 || die "the docker daemon is not reachable; start Docker first"

  if [[ "$COMMAND" == "up" ]]; then
    python3 -c 'import socket, sys
socket.getaddrinfo(sys.argv[1], 80)' "$GITLAB_HOST" >/dev/null 2>&1 ||
      die "'${GITLAB_HOST}' does not resolve on this machine. The default name is served by the public nip.io wildcard DNS, so it needs working outbound DNS; pass --host with a name both the browser and the containers can resolve."
    [[ -n "$(git config --get user.name || true)" && -n "$(git config --get user.email || true)" ]] ||
      die "set a git identity first, for example: git config --global user.name 'xinchen' && git config --global user.email 'you@example.com'"
  fi

  [[ -f "$COMPOSE_FILE" ]] || die "missing ${COMPOSE_FILE}"
}

prepare_directories() {
  local subdir
  for subdir in config logs data runner-config projects; do
    mkdir -p "${GITLAB_DIR}/${subdir}"
  done
  chmod 700 "$GITLAB_DIR"
}

start_stack() {
  compose up --no-build --detach
}

wait_for_gitlab() {
  if gitlab_is_serving; then
    log "GitLab API already answering at ${GITLAB_URL}"
    return 0
  fi

  step "waiting for GitLab to finish booting (a first start takes several minutes)"
  local waited=0
  while true; do
    sleep 15
    waited=$((waited + 15))
    if gitlab_is_serving; then
      log "GitLab API is answering after ${waited}s"
      return 0
    fi
    log "  ... $(container_health gitlab) after ${waited}s"
    if ((waited >= READY_TIMEOUT)); then
      die "GitLab was not ready within ${READY_TIMEOUT}s; check 'docker logs gitlab' and the reconfigure log at ${GITLAB_DIR}/logs/reconfigure/"
    fi
  done
}

# The root password of an existing install is not known to this script, and asking for it
# would make the run interactive, so mint a short-lived token through the Rails console.
ensure_token() {
  if [[ -f "$TOKEN_FILE" ]]; then
    TOKEN=$(<"$TOKEN_FILE")
    if [[ -n "$TOKEN" ]] && api GET /user | looks_like_user_json; then
      log "reusing the API token at ${TOKEN_FILE}"
      return 0
    fi
    warn "the stored token is no longer accepted; creating a new one"
  fi

  step "creating a 30-day API token for the root user"
  TOKEN=$(openssl rand -hex 24)
  (
    umask 077
    printf '%s\n' "$TOKEN" >"$TOKEN_FILE"
  )

  local script_path="${GITLAB_DIR}/config/dev-env-token.rb"
  cat >"$script_path" <<'RUBY'
token_secret = ENV.fetch('DEV_ENV_TOKEN')
user = User.find_by_username('root')
abort 'the root user does not exist yet' unless user

user.personal_access_tokens.active.where(name: 'dev-env-local').each(&:revoke!)

token = PersonalAccessToken.new(
  user: user,
  name: 'dev-env-local',
  scopes: %i[api read_repository write_repository],
  expires_at: Time.current + 30.days
)
token.set_token(token_secret)
abort 'could not create the personal access token' unless token.save

puts "created personal access token ##{token.id} for #{user.username}"
RUBY
  chmod 600 "$script_path"

  docker exec -i -e DEV_ENV_TOKEN="$TOKEN" gitlab \
    /opt/gitlab/bin/gitlab-rails runner /etc/gitlab/dev-env-token.rb ||
    die "could not create an API token; see the output above"

  log "token stored at ${TOKEN_FILE} (mode 600, expires in 30 days)"
}

ensure_project() {
  local encoded
  encoded=$(urlencode "$PROJECT_PATH")

  PROJECT_ID=$(api GET "/projects/${encoded}" | json_field id)
  if [[ -n "$PROJECT_ID" ]]; then
    log "project ${PROJECT_PATH} already exists (id ${PROJECT_ID})"
    return 0
  fi

  step "creating project ${PROJECT_PATH}"
  local user_id body created
  user_id=$(api GET /user | json_field id)
  body=$(python3 -c 'import json, sys
print(json.dumps({
    "name": sys.argv[1],
    "path": sys.argv[1],
    "namespace_id": int(sys.argv[2]),
    "description": "Local GitLab CI smoke project created by gitlab-ci.sh",
    "visibility": "private",
    "default_branch": "main",
    "initialize_with_readme": False,
}))' "$DEMO_PROJECT" "$user_id")
  created=$(api POST /projects "$body" | json_field id)
  [[ -n "$created" ]] || die "could not create ${PROJECT_PATH}; check that ${TOKEN_FILE} is still valid"
  PROJECT_ID=$created
  log "created project ${PROJECT_PATH} (id ${PROJECT_ID})"
}

# A runner can take the demo pipeline only when it is online, accepts untagged jobs and
# carries the tag the tagged demo job asks for.
runner_is_usable() {
  python3 -c 'import json, sys
runner = json.load(sys.stdin)
sys.exit(0 if runner.get("online") and runner.get("active") and runner.get("run_untagged")
         and sys.argv[1] in (runner.get("tag_list") or []) else 1)' "$RUNNER_TAG"
}

available_online_runner() {
  local id detail
  for id in $(api GET "/runners/all?per_page=100" | python3 -c 'import json, sys
for runner in json.load(sys.stdin) or []:
    if runner.get("online") and runner.get("active"):
        print(runner["id"])'); do
    detail=$(api GET "/runners/${id}")
    if printf '%s' "$detail" | runner_is_usable; then
      printf '%s %s\n' "$id" "$(printf '%s' "$detail" | json_field description)"
      return 0
    fi
  done
  return 0
}

# GitLab 18 removed the old registration tokens, so the runner record is created through
# the API and its glrt- authentication token is handed to 'gitlab-runner register'.
ensure_runner() {
  local existing
  existing=$(available_online_runner)
  if [[ -n "$existing" ]]; then
    RUNNER_SUMMARY=$existing
    log "runner already online and usable: ${existing}"
    return 0
  fi

  step "registering runner '${RUNNER_DESCRIPTION}' (tags: ${RUNNER_TAG})"
  local id body created token runner_id
  for id in $(api GET "/runners/all?per_page=100" | python3 -c 'import json, sys
for runner in json.load(sys.stdin) or []:
    if runner.get("description") == sys.argv[1] and runner.get("status") == "never_contacted":
        print(runner["id"])' "$RUNNER_DESCRIPTION"); do
    warn "dropping runner record ${id}, it never contacted this GitLab"
    api DELETE "/runners/${id}" >/dev/null
  done

  body=$(python3 -c 'import json, sys
print(json.dumps({
    "description": sys.argv[1],
    "runner_type": "instance_type",
    "tag_list": sys.argv[2].split(","),
    "run_untagged": True,
    "maximum_timeout": 3600,
}))' "$RUNNER_DESCRIPTION" "$RUNNER_TAG")
  created=$(api POST /user/runners "$body")
  token=$(printf '%s\n' "$created" | json_field token)
  runner_id=$(printf '%s\n' "$created" | json_field id)
  [[ -n "$token" && "$token" == glrt-* ]] ||
    die "could not create a runner through the API: ${created}"

  # With a glrt- token the tags and run_untagged live on the server side (set by the API
  # call above), and 'register' refuses to accept them locally.
  docker exec -i gitlab-runner gitlab-runner register \
    --non-interactive \
    --url "${GITLAB_URL}/" \
    --token "$token" \
    --executor docker \
    --docker-image alpine:latest \
    --description "$RUNNER_DESCRIPTION" \
    --docker-volumes /cache \
    --docker-network-mode "$GITLAB_NETWORK" \
    --docker-pull-policy if-not-present ||
    die "'gitlab-runner register' failed; check 'docker logs gitlab-runner'"

  local waited=0
  until [[ -n "$(available_online_runner)" ]]; do
    sleep 5
    waited=$((waited + 5))
    if ((waited >= 120)); then
      die "the runner stayed offline for 120s; check 'docker logs gitlab-runner' and that ${GITLAB_URL} is reachable from inside it"
    fi
  done
  RUNNER_SUMMARY="${runner_id} ${RUNNER_DESCRIPTION}"
  log "runner ${RUNNER_SUMMARY} is online"
}

write_demo_ci_file() {
  local repo_dir=$1
  cat >"${repo_dir}/.gitlab-ci.yml" <<YAML
stages:
  - verify

untagged-job:
  stage: verify
  image: alpine:latest
  script:
    - echo "hello from GitLab CI"
    - echo "project \${CI_PROJECT_PATH} pipeline \${CI_PIPELINE_ID} runner \${CI_RUNNER_DESCRIPTION}"
    - uname -a

tagged-job:
  stage: verify
  tags:
    - ${RUNNER_TAG}
  image: alpine:latest
  script:
    - echo "this job only runs on a runner tagged ${RUNNER_TAG}"
    - date
YAML
}

push_demo_project() {
  local repo_dir="${GITLAB_DIR}/projects/${DEMO_PROJECT}"
  local auth
  auth=$(printf 'oauth2:%s' "$TOKEN" | openssl base64 -A)

  if [[ ! -d "$repo_dir/.git" ]]; then
    step "creating the local demo checkout at ${repo_dir}"
    git init -q -b main "$repo_dir"
  else
    log "reusing the local demo checkout at ${repo_dir}"
  fi

  git -C "$repo_dir" config remote.origin.url "${GITLAB_URL}/${PROJECT_PATH}.git"

  write_demo_ci_file "$repo_dir"
  if ! git -C "$repo_dir" rev-parse --verify HEAD >/dev/null 2>&1; then
    printf '# %s\n\nSmoke project used by `gitlab-ci.sh` to prove the local runner executes CI jobs.\n' "$DEMO_PROJECT" >"${repo_dir}/README.md"
  fi
  git -C "$repo_dir" add -A

  if git -C "$repo_dir" diff --cached --quiet; then
    log "demo project already committed and pushed"
  else
    git -C "$repo_dir" commit -q -m "chore: update GitLab CI demo pipeline"
    git -C "$repo_dir" -c http.extraHeader="Authorization: Basic ${auth}" \
      push -q origin HEAD:refs/heads/main ||
      die "git push to ${GITLAB_URL}/${PROJECT_PATH}.git failed"
    log "pushed the demo project to ${PROJECT_URL}"
  fi

  DEMO_SHA=$(git -C "$repo_dir" rev-parse HEAD)
}

find_pipeline() {
  api GET "/projects/${PROJECT_ID}/pipelines?sha=${DEMO_SHA}&per_page=1" | json_first id
}

trigger_pipeline() {
  api POST "/projects/${PROJECT_ID}/pipeline?ref=main" | json_field id
}

pipeline_status() {
  api GET "/projects/${PROJECT_ID}/pipelines/${1}" | json_field status
}

run_demo_pipeline() {
  local pipeline_id waited=0 status
  pipeline_id=$(find_pipeline)
  until [[ -n "$pipeline_id" ]]; do
    sleep 5
    waited=$((waited + 5))
    if ((waited >= 60)); then
      pipeline_id=$(trigger_pipeline)
      break
    fi
    pipeline_id=$(find_pipeline)
  done
  [[ -n "$pipeline_id" ]] || die "no pipeline was created for ${DEMO_SHA:-unknown sha}"

  # A pipeline left behind by an earlier failed run can never turn green, so start a fresh
  # one instead of reporting the stale result.
  status=$(pipeline_status "$pipeline_id")
  if [[ "$status" == "failed" || "$status" == "canceled" || "$status" == "skipped" ]]; then
    warn "pipeline ${pipeline_id} is ${status}; starting a new one for the same commit"
    pipeline_id=$(trigger_pipeline)
    [[ -n "$pipeline_id" ]] || die "could not start a new pipeline for ${PROJECT_PATH}"
  fi

  wait_for_pipeline "$pipeline_id"
}

wait_for_pipeline() {
  local pipeline_id=$1
  local waited=0 status

  log "pipeline ${pipeline_id}: ${PROJECT_URL}/pipelines/${pipeline_id}"
  while true; do
    status=$(pipeline_status "$pipeline_id")
    case "$status" in
      success)
        log "pipeline ${pipeline_id} succeeded"
        return 0
        ;;
      failed | canceled | skipped)
        warn "pipeline ${pipeline_id} finished as ${status}; failing jobs:"
        show_failed_jobs "$pipeline_id"
        die "the demo pipeline did not pass"
        ;;
      *)
        log "  pipeline ${pipeline_id} is ${status:-created} (${waited}s)"
        ;;
    esac
    if ((waited >= PIPELINE_TIMEOUT)); then
      die "pipeline ${pipeline_id} did not finish within ${PIPELINE_TIMEOUT}s; the runner may be offline or the image may be missing"
    fi
    sleep 10
    waited=$((waited + 10))
  done
}

show_failed_jobs() {
  local pipeline_id=$1
  local jobs job_id
  jobs=$(api GET "/projects/${PROJECT_ID}/pipelines/${pipeline_id}/jobs")
  printf '%s\n' "$jobs" |
    python3 -c 'import json, sys
data = json.load(sys.stdin)
for job in data if isinstance(data, list) else []:
    if job.get("status") in ("failed", "canceled"):
        print(job["id"])' |
    while read -r job_id; do
      [[ -n "$job_id" ]] || continue
      printf '\n--- job %s trace ---\n' "$job_id"
      api GET "/projects/${PROJECT_ID}/jobs/${job_id}/trace" | tail -30
    done
}

report() {
  step "ready"
  cat <<EOF
GitLab UI     ${GITLAB_URL}   (username root)
Demo project  ${PROJECT_URL}
Pipeline      ${PROJECT_URL}/pipelines   (latest for ${DEMO_SHA:-unknown} passed)
Runner        #${RUNNER_SUMMARY:-unknown} (online, takes jobs tagged '${RUNNER_TAG}'), Docker executor on network '${GITLAB_NETWORK}'
API token     ${TOKEN_FILE}   (also used as git password: oauth2/<token>)
Data          ${GITLAB_DIR}/{config,logs,data,runner-config,projects}

Use it from another repository:
  git remote add gitlab ${GITLAB_URL}/${PROJECT_PATH}.git
  then put 'tags: [${RUNNER_TAG}]' on the jobs that need this runner
EOF
}

cmd_up() {
  step "GitLab ${GITLAB_URL} with data in ${GITLAB_DIR}"
  prepare_directories
  start_stack
  wait_for_gitlab
  ensure_token
  ensure_project
  ensure_runner
  push_demo_project
  run_demo_pipeline
  report
}

cmd_status() {
  step "containers"
  printf 'gitlab        %s\n' "$(container_health gitlab)"
  printf 'gitlab-runner %s\n' "$(container_health gitlab-runner)"

  if [[ ! -f "$TOKEN_FILE" ]]; then
    warn "no API token yet at ${TOKEN_FILE}; run '$0 up' to create one"
    return 0
  fi
  TOKEN=$(<"$TOKEN_FILE")

  step "runners"
  api GET "/runners/all?per_page=100" | python3 -c 'import json, sys
for runner in json.load(sys.stdin) or []:
    print("  #{0} {1}  {2}  shared={3}".format(
        runner.get("id"), runner.get("status"), runner.get("description"), runner.get("is_shared")))'

  local project_id
  project_id=$(api GET "/projects/$(urlencode "$PROJECT_PATH")" | json_field id)
  if [[ -z "$project_id" ]]; then
    warn "project ${PROJECT_PATH} does not exist yet; run '$0 up'"
    return 0
  fi

  step "latest pipelines of ${PROJECT_PATH}"
  api GET "/projects/${project_id}/pipelines?per_page=3" | python3 -c 'import json, sys
for pipeline in json.load(sys.stdin) or []:
    print("  #{0} {1} on {2} -> {3}".format(
        pipeline.get("id"), pipeline.get("sha", "")[:8], pipeline.get("ref"), pipeline.get("status")))'
}

cmd_down() {
  compose down
  log "containers stopped; ${GITLAB_DIR} still holds config, logs, data and the runner registration"
}

preflight
case "$COMMAND" in
  up) cmd_up ;;
  status) cmd_status ;;
  down) cmd_down ;;
esac
