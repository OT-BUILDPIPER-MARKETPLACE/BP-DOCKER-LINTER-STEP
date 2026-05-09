#!/usr/bin/env bash

set -euo pipefail

source /opt/buildpiper/shell-functions/functions.sh
source /opt/buildpiper/shell-functions/log-functions.sh
source /opt/buildpiper/shell-functions/file-functions.sh
source /opt/buildpiper/shell-functions/str-functions.sh
source /opt/buildpiper/shell-functions/getDataFile.sh

# ---------------------------------------------------------------
# NOTE:
# ACTIVITY_SUB_TASK_CODE is managed by BuildPiper.
# Do NOT override it manually.
# ---------------------------------------------------------------

###############################################
### DEBUG MODE
###############################################
if [[ "${DEBUG:-false}" == "true" ]]; then
  set -x
fi

###############################################
### OUTPUT FILES
###############################################
DOCKER_LINTER_OUTPUT_FILE="${DOCKER_LINTER_OUTPUT_FILE:-${ACTIVITY_SUB_TASK_CODE}_output.json}"

###############################################
### CONFIGURATION
###############################################
WORKSPACE="${WORKSPACE:-/bp/workspace}"
CODEBASE_LOCATION="${WORKSPACE}/${CODEBASE_DIR}"

EXEC_DIR="/bp/execution_dir/${GLOBAL_TASK_ID}"

MERGED_JSON="docker_lint.json"
MERGED_CSV="docker_lint.csv"
RAW_JSON="docker_lint_raw.json"

SLEEP_DURATION="${SLEEP_DURATION:-0}"
HADOLINT_FAIL_THRESHOLD="${HADOLINT_FAIL_THRESHOLD:-error}"

VALIDATION_ACTION="${VALIDATION_FAILURE_ACTION:-FAILURE}"

###############################################
### EVENTS TRACKING
###############################################
EVENTS='{}'

add_event() {
  local key="${1:-}"
  local status="${2:-}"
  local reason="${3:-}"
  local message="${4:-}"

  if [[ -z "$key" || -z "$status" ]]; then
    echo "Error: add_event requires key and status" >&2
    return 1
  fi

  key="$(echo "$key" \
      | tr '_' ' ' \
      | tr '-' ' ' \
      | tr '[:upper:]' '[:lower:]')"

  EVENTS=$(jq \
    --arg k "$key" \
    --arg status "$status" \
    --arg reason "$reason" \
    --arg message "$message" \
    '. + {
      ($k): {
        status: $status,
        reason: $reason,
        message: $message
      }
    }' <<< "$EVENTS")
}

###############################################
### INITIALIZATION
###############################################
logInfoMessage "====================================="
logInfoMessage "Starting Dockerfile Hadolint Scan"
logInfoMessage "====================================="

mkdir -p "${EXEC_DIR}"
chmod -R 777 "${EXEC_DIR}" || true

add_event "initialization" "Successful" \
"Hadolint step initialized" \
"Workspace=${WORKSPACE} Codebase=${CODEBASE_DIR}"

sleep "${SLEEP_DURATION}"

###############################################
### VALIDATE CODEBASE
###############################################
if [[ ! -d "${CODEBASE_LOCATION}" ]]; then

    logErrorMessage "Codebase directory not found"

    add_event "workspace validation" "Failed" \
    "Directory missing" \
    "${CODEBASE_LOCATION}"

    generateOutput "${ACTIVITY_SUB_TASK_CODE}" false \
    "Codebase directory not found"

    exit 1
fi

cd "${CODEBASE_LOCATION}"

add_event "workspace validation" "Successful" \
"Workspace accessible" \
"${CODEBASE_LOCATION}"

###############################################
### RESOLVE DOCKERFILE PATH
###############################################
dockerfile_path() {
    jq -r '.build_detail.dockerfile_path // empty' \
    < /bp/data/environment_build
}

logInfoMessage "Resolving Dockerfile path"

DOCKERFILE_PATH=$(dockerfile_path)

if [[ -z "${DOCKERFILE_PATH}" ]]; then

    logErrorMessage "dockerfile_path missing"

    add_event "dockerfile resolution" "Failed" \
    "Path not configured" \
    "dockerfile_path missing in build_detail"

    generateOutput "${ACTIVITY_SUB_TASK_CODE}" false \
    "Dockerfile path missing in build configuration"

    exit 1
fi

if [[ "${DOCKERFILE_PATH}" == *:* ]]; then

    DOCKERFILE_NAME="${DOCKERFILE_PATH%%:*}"
    DOCKERFILE_DIR="${DOCKERFILE_PATH##*:}"

else

    DOCKERFILE_NAME=$(basename "${DOCKERFILE_PATH}")
    DOCKERFILE_DIR=$(dirname "${DOCKERFILE_PATH}")
fi

DOCKERFILE_FULL_PATH="${DOCKERFILE_DIR}/${DOCKERFILE_NAME}"

logInfoMessage "Dockerfile -> ${DOCKERFILE_FULL_PATH}"

add_event "dockerfile resolution" "Successful" \
"Dockerfile resolved" \
"${DOCKERFILE_FULL_PATH}"

###############################################
### VALIDATE DOCKERFILE
###############################################
if [[ ! -f "${DOCKERFILE_FULL_PATH}" ]]; then

    logErrorMessage "Dockerfile not found"

    add_event "dockerfile validation" "Failed" \
    "Dockerfile missing" \
    "${DOCKERFILE_FULL_PATH}"

    generateOutput "${ACTIVITY_SUB_TASK_CODE}" false \
    "Dockerfile not found"

    exit 1
fi

FILE_SIZE=$(stat -c%s "${DOCKERFILE_FULL_PATH}" 2>/dev/null || echo 0)

logInfoMessage "Dockerfile size -> ${FILE_SIZE}"

add_event "dockerfile validation" "Successful" \
"Dockerfile exists" \
"Size=${FILE_SIZE}"

###############################################
### VERIFY HADOLINT
###############################################
logInfoMessage "Checking Hadolint installation"

if ! command -v hadolint >/dev/null 2>&1; then

    logErrorMessage "Hadolint not installed"

    add_event "tool verification" "Failed" \
    "Hadolint missing" \
    "Binary not found in PATH"

    generateOutput "${ACTIVITY_SUB_TASK_CODE}" false \
    "Hadolint binary not found"

    exit 1
fi

HADOLINT_VERSION=$(hadolint --version | head -1 || echo "unknown")

logInfoMessage "Using ${HADOLINT_VERSION}"

add_event "tool verification" "Successful" \
"Hadolint available" \
"${HADOLINT_VERSION}"

###############################################
### RUN HADOLINT
###############################################
logInfoMessage "Starting Hadolint scan"

add_event "hadolint scan" "Successful" \
"Scan started" \
"${DOCKERFILE_FULL_PATH}"

set +e

hadolint \
"${DOCKERFILE_FULL_PATH}" \
--format json \
> "${RAW_JSON}" \
2>/tmp/hadolint.stderr

HADOLINT_EXIT_CODE=$?

set -e

if [[ -s /tmp/hadolint.stderr ]]; then

    logWarningMessage "Hadolint stderr output"

    cat /tmp/hadolint.stderr
fi

if [[ ! -s "${RAW_JSON}" ]]; then

    echo "[]" > "${RAW_JSON}"
fi

chmod 777 "${RAW_JSON}" || true

logInfoMessage "Hadolint exit code=${HADOLINT_EXIT_CODE}"

###############################################
### PARSE RESULTS
###############################################
TOTAL_ISSUES=$(jq 'length' "${RAW_JSON}" 2>/dev/null || echo 0)

ERROR_COUNT=$(jq \
'[.[] | select(.level=="error")] | length' \
"${RAW_JSON}" 2>/dev/null || echo 0)

WARNING_COUNT=$(jq \
'[.[] | select(.level=="warning")] | length' \
"${RAW_JSON}" 2>/dev/null || echo 0)

INFO_COUNT=$(jq \
'[.[] | select(.level=="info")] | length' \
"${RAW_JSON}" 2>/dev/null || echo 0)

STYLE_COUNT=$(jq \
'[.[] | select(.level=="style")] | length' \
"${RAW_JSON}" 2>/dev/null || echo 0)

logInfoMessage "TOTAL=${TOTAL_ISSUES}"
logInfoMessage "ERROR=${ERROR_COUNT}"
logInfoMessage "WARNING=${WARNING_COUNT}"
logInfoMessage "INFO=${INFO_COUNT}"
logInfoMessage "STYLE=${STYLE_COUNT}"

add_event "parse results" "Successful" \
"Metrics extracted" \
"TOTAL=${TOTAL_ISSUES} ERROR=${ERROR_COUNT} WARNING=${WARNING_COUNT}"

###############################################
### GENERATE CSV REPORT
###############################################
echo "rule,level,message,line,column" > "${MERGED_CSV}"

jq -r '
  .[] |
  [
    (.code // "UNKNOWN"),
    (.level // "unknown"),
    (.message // "" | gsub("\n"; " ") | gsub("\r"; " ")),
    (.line // 0),
    (.column // 0)
  ] | @csv
' "${RAW_JSON}" >> "${MERGED_CSV}" 2>/dev/null || true

chmod 777 "${MERGED_CSV}" || true

###############################################
### GENERATE JSON REPORT
###############################################
jq -n \
  --slurpfile issues "${RAW_JSON}" \
  --arg dockerfile "${DOCKERFILE_FULL_PATH}" \
  --argjson exit_code "${HADOLINT_EXIT_CODE}" \
'{
  dockerfile: $dockerfile,
  hadolint_exit_code: $exit_code,
  issues: $issues[0],
  summary: {
    total: ($issues[0] | length),
    error: ($issues[0] | [.[] | select(.level=="error")] | length),
    warning: ($issues[0] | [.[] | select(.level=="warning")] | length),
    info: ($issues[0] | [.[] | select(.level=="info")] | length),
    style: ($issues[0] | [.[] | select(.level=="style")] | length)
  }
}' > "${MERGED_JSON}"

chmod 777 "${MERGED_JSON}" || true

###############################################
### COPY REPORTS
###############################################
cp -f "${MERGED_JSON}" "${EXEC_DIR}/" || true
cp -f "${MERGED_CSV}" "${EXEC_DIR}/" || true

add_event "copy reports" "Successful" \
"Reports copied" \
"${EXEC_DIR}"

###############################################
### THRESHOLD VALIDATION
###############################################
STATUS=0
FAILURE_REASON=""

case "${HADOLINT_FAIL_THRESHOLD}" in

  error)
    if [[ "${ERROR_COUNT}" -gt 0 ]]; then
        STATUS=1
        FAILURE_REASON="Found ${ERROR_COUNT} error(s)"
    fi
    ;;

  warning)
    if [[ "${ERROR_COUNT}" -gt 0 || "${WARNING_COUNT}" -gt 0 ]]; then
        STATUS=1
        FAILURE_REASON="Found errors/warnings"
    fi
    ;;

  info)
    if [[ "${ERROR_COUNT}" -gt 0 || \
          "${WARNING_COUNT}" -gt 0 || \
          "${INFO_COUNT}" -gt 0 ]]; then
        STATUS=1
        FAILURE_REASON="Found errors/warnings/info"
    fi
    ;;

  style)
    if [[ "${TOTAL_ISSUES}" -gt 0 ]]; then
        STATUS=1
        FAILURE_REASON="Found lint issues"
    fi
    ;;

  ignore|none)
    STATUS=0
    ;;

  *)
    if [[ "${ERROR_COUNT}" -gt 0 ]]; then
        STATUS=1
        FAILURE_REASON="Found ${ERROR_COUNT} error(s)"
    fi
    ;;
esac

if [[ "${STATUS}" -eq 0 ]]; then

    add_event "threshold validation" "Successful" \
    "Threshold passed" \
    "Issues within threshold"

else

    add_event "threshold validation" "Failed" \
    "Threshold breached" \
    "${FAILURE_REASON}"
fi

###############################################
### FINAL MESSAGE
###############################################
FINAL_MESSAGE="TOTAL=${TOTAL_ISSUES} ERROR=${ERROR_COUNT} WARNING=${WARNING_COUNT} INFO=${INFO_COUNT} STYLE=${STYLE_COUNT}"

if [[ "${STATUS}" -eq 0 ]]; then
    FINAL_STATUS="Successful"
else
    FINAL_STATUS="Failed"
fi

add_event "scan summary" "${FINAL_STATUS}" \
"Hadolint scan completed" \
"${FINAL_MESSAGE}"

###############################################
### ERROR EVENTS
###############################################
ERROR_EVENTS=$(echo "${EVENTS}" | jq '
[
  to_entries[]
  | select(.value.status == "Failed")
  | .key
]')

###############################################
### OUTPUT JSON
###############################################
jq -n \
  --argjson events "${EVENTS}" \
  --argjson error_events "${ERROR_EVENTS}" \
  --arg status "${FINAL_STATUS}" \
  --arg message "${FINAL_MESSAGE}" \
  --arg total "${TOTAL_ISSUES}" \
  --arg error "${ERROR_COUNT}" \
  --arg warning "${WARNING_COUNT}" \
  --arg info "${INFO_COUNT}" \
  --arg style "${STYLE_COUNT}" \
'{
  build: {
    status: ($status == "Successful"),
    message: $message,
    events: $events,
    error_events: $error_events
  },
  output_vars: {
    docker_linter: {
      status: $status,
      message: $message,
      summary: {
        total: ($total|tonumber),
        error: ($error|tonumber),
        warning: ($warning|tonumber),
        info: ($info|tonumber),
        style: ($style|tonumber)
      }
    }
  }
}' > "${EXEC_DIR}/${DOCKER_LINTER_OUTPUT_FILE}"

chmod 777 "${EXEC_DIR}/${DOCKER_LINTER_OUTPUT_FILE}" || true

logInfoMessage "Output written -> ${EXEC_DIR}/${DOCKER_LINTER_OUTPUT_FILE}"

###############################################
### FINAL PIPELINE STATUS
###############################################
if [[ "${STATUS}" -eq 0 ]]; then

    logInfoMessage "Dockerfile linting succeeded"

    generateOutput "${ACTIVITY_SUB_TASK_CODE}" true \
    "${FINAL_MESSAGE}"

else

    if [[ "${VALIDATION_ACTION}" == "FAILURE" ]]; then

        logErrorMessage "Dockerfile linting failed"

        generateOutput "${ACTIVITY_SUB_TASK_CODE}" false \
        "${FAILURE_REASON}"

        exit 1

    else

        logWarningMessage "Validation ignored due to NON-BLOCKING mode"

        generateOutput "${ACTIVITY_SUB_TASK_CODE}" false \
        "${FAILURE_REASON}"
    fi
fi

saveTaskStatus "${STATUS}" "${ACTIVITY_SUB_TASK_CODE}"

logInfoMessage "Dockerfile Hadolint Scan completed"

exit 0