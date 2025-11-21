#!/bin/bash
set -euo pipefail

# ==============================================================================
#  Load BuildPiper Base Functions
# ==============================================================================
source /opt/buildpiper/shell-functions/functions.sh
source /opt/buildpiper/shell-functions/log-functions.sh
source /opt/buildpiper/shell-functions/file-functions.sh
source /opt/buildpiper/shell-functions/str-functions.sh
source /opt/buildpiper/shell-functions/getDataFile.sh

# ==============================================================================
#  Environment
# ==============================================================================
CODEBASE_LOCATION="${WORKSPACE}/${CODEBASE_DIR}"
REPORTS_DIR="${CODEBASE_LOCATION}/reports"
EXEC_DIR="/bp/execution_dir/${GLOBAL_TASK_ID}"

MERGED_JSON="${REPORTS_DIR}/docker_lint.json"
MERGED_CSV="${REPORTS_DIR}/docker_lint.csv"

mkdir -p "${REPORTS_DIR}"
chmod -R 0777 "${REPORTS_DIR}" || true

logInfoMessage "=============================================================="
logInfoMessage " Starting Dockerfile Linting (Hadolint)"
logInfoMessage "=============================================================="
logInfoMessage " Codebase location : ${CODEBASE_LOCATION}"
logInfoMessage " Reports directory : ${REPORTS_DIR}"
logInfoMessage " Dockerfile path   : ${DOCKERFILE_PATH}"
logInfoMessage "=============================================================="

# ==============================================================================
#  Validate dockerfile exists
# ==============================================================================
if [[ ! -f "${CODEBASE_LOCATION}/${DOCKERFILE_PATH}" ]]; then
    logWarningMessage "Dockerfile not found at ${CODEBASE_LOCATION}/${DOCKERFILE_PATH}"
    mkdir -p "${EXEC_DIR}"
    echo "{}" > "${MERGED_JSON}"
    echo "rule,level,message,line,column" > "${MERGED_CSV}"
    cp -f "${MERGED_JSON}" "${EXEC_DIR}/"
    cp -f "${MERGED_CSV}" "${EXEC_DIR}/"
    exit 0
fi

DOCKERFILE_FULL_PATH="${CODEBASE_LOCATION}/${DOCKERFILE_PATH}"

# ==============================================================================
#  Run Hadolint
# ==============================================================================
RAW_JSON="${REPORTS_DIR}/docker_lint_raw.json"

logInfoMessage "Running hadolint..."
set +e
hadolint "${DOCKERFILE_FULL_PATH}" --format json > "${RAW_JSON}" 2>/tmp/hadolint.stderr
EXIT_CODE=$?
set -e

chmod 777 "${RAW_JSON}"

# ==============================================================================
#  If hadolint crashed OR returned empty json
# ==============================================================================
if [[ ! -s "${RAW_JSON}" ]]; then
    logWarningMessage "Hadolint returned empty output, creating skeleton JSON"
    echo "[]" > "${RAW_JSON}"
fi

# ==============================================================================
#  Count issues
# ==============================================================================
ISSUE_COUNT=$(jq 'length' "${RAW_JSON}" 2>/dev/null || echo 0)

logInfoMessage "Found ${ISSUE_COUNT} issue(s) in Dockerfile."

# ==============================================================================
#  Build CSV
# ==============================================================================
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

# ==============================================================================
#  Build final JSON
# ==============================================================================
logInfoMessage "Building final JSON report..."

jq -n \
    --slurpfile issues "${RAW_JSON}" \
    '{
        issues: $issues[0],
        total_issues: ($issues[0] | length)
    }' > "${MERGED_JSON}"

chmod 777 "${MERGED_JSON}"

# ==============================================================================
#  Copy to execution directory
# ==============================================================================
mkdir -p "${EXEC_DIR}"
cp -f "${MERGED_JSON}" "${EXEC_DIR}/"
cp -f "${MERGED_CSV}" "${EXEC_DIR}/"

# ==============================================================================
#  Determine Pass/Fail
# ==============================================================================
if [[ $EXIT_CODE -eq 0 ]]; then
    logInfoMessage "Docker Lint succeeded with no severe violations."
    generateOutput docker_lint true "Docker lint scan succeeded."
else
    if [[ "${VALIDATION_FAILURE_ACTION}" == "FAILURE" ]]; then
        logErrorMessage "Docker lint scan failed!"
        generateOutput docker_lint false "Docker lint scan failed."
        exit 1
    else
        logWarningMessage "Docker lint reported issues but allowed to proceed (VALIDATION_FAILURE_ACTION=WARNING)"
        generateOutput docker_lint true "Docker lint scan completed with warnings."
    fi
fi

logInfoMessage "=============================================================="
logInfoMessage " Dockerfile Linting Step Completed"
logInfoMessage "=============================================================="

exit 0

