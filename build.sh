#!/bin/bash
set -euo pipefail


if [ "$DEBUG" = true ]; then
  set -x
fi

source /opt/buildpiper/shell-functions/functions.sh
source /opt/buildpiper/shell-functions/log-functions.sh
source /opt/buildpiper/shell-functions/file-functions.sh
source /opt/buildpiper/shell-functions/str-functions.sh
source /opt/buildpiper/shell-functions/getDataFile.sh


CODEBASE_LOCATION="${WORKSPACE}/${CODEBASE_DIR}"
REPORTS_DIR="${CODEBASE_LOCATION}/reports"
EXEC_DIR="/bp/execution_dir/${GLOBAL_TASK_ID}"

sleep  $SLEEP_DURATION
MERGED_JSON="${REPORTS_DIR}/docker_lint.json"
MERGED_CSV="${REPORTS_DIR}/docker_lint.csv"

mkdir -p "${REPORTS_DIR}"
chmod -R 0777 "${REPORTS_DIR}" || true



function dockerfile_path() {
  COMPONENT_NAME=$(jq -r .build_detail.dockerfile_path < /bp/data/environment_build )
  echo "$COMPONENT_NAME"
}

DOCKERFILE_PATH=$(dockerfile_path)

DOCKERFILE_NAME="${DOCKERFILE_PATH%%:*}"
DOCKERFILE_DIR="${DOCKERFILE_PATH##*:}"

logInfoMessage "Detected Dockerfile Name: $DOCKERFILE_NAME"
logInfoMessage "Detected Dockerfile Directory: $DOCKERFILE_DIR"

DOCKERFILE_FULL_PATH="$DOCKERFILE_DIR/$DOCKERFILE_NAME"


logInfoMessage "=============================================================="
logInfoMessage " Starting Dockerfile Linting (Hadolint)"
logInfoMessage "=============================================================="
logInfoMessage " Codebase location : ${CODEBASE_LOCATION}"
logInfoMessage " Reports directory : ${REPORTS_DIR}"
logInfoMessage " Dockerfile path   : ${DOCKERFILE_FULL_PATH}"
logInfoMessage "=============================================================="

if [[ ! -f "${CODEBASE_LOCATION}/${DOCKERFILE_FULL_PATH}" ]]; then
    logWarningMessage "Dockerfile not found at ${CODEBASE_LOCATION}/${DOCKERFILE_PATH}"
    exit 1
fi


RAW_JSON="${REPORTS_DIR}/docker_lint_raw.json"

logInfoMessage "Running hadolint..."
set +e
hadolint "${DOCKERFILE_FULL_PATH}" --format json > "${RAW_JSON}" 2>/tmp/hadolint.stderr
TASK_STATUS=$?
set -e

chmod 777 "${RAW_JSON}"

if [[ ! -s "${RAW_JSON}" ]]; then
    logWarningMessage "Hadolint returned empty output, creating skeleton JSON"
    echo "[]" > "${RAW_JSON}"
fi

ISSUE_COUNT=$(jq 'length' "${RAW_JSON}" 2>/dev/null || echo 0)

logInfoMessage "Found ${ISSUE_COUNT} issue(s) in Dockerfile."

echo "rule,level,message,line,column" > "${MERGED_CSV}"
chmod 777 "${MERGED_CSV}"

jq -r '
    .[] |
    [
        (.code // ""),
        (.level // ""),
        (.message // "" | gsub("\n"; " ") | gsub("\r"; "")),
        (.line // 0),
        (.column // 0)
    ] | @csv
' "${RAW_JSON}" >> "${MERGED_CSV}" || true

chmod 777 "${MERGED_CSV}"

logInfoMessage "Building final JSON report..."

jq -n \
    --slurpfile issues "${RAW_JSON}" \
    '{
        issues: $issues[0],
        total_issues: ($issues[0] | length)
    }' > "${MERGED_JSON}"

chmod 777 "${MERGED_JSON}"
cp -f "${MERGED_JSON}" "${EXEC_DIR}/"
cp -f "${MERGED_CSV}" "${EXEC_DIR}/"


TASK_STATUS=$?
saveTaskStatus ${TASK_STATUS} ${ACTIVITY_SUB_TASK_CODE}
