#!/bin/bash

source /opt/buildpiper/shell-functions/functions.sh
source /opt/buildpiper/shell-functions/log-functions.sh
source /opt/buildpiper/shell-functions/file-functions.sh
source /opt/buildpiper/shell-functions/str-functions.sh
source /opt/buildpiper/shell-functions/getDataFile.sh

# ---------------------------------------------------------------
# NOTE: ACTIVITY_SUB_TASK_CODE is managed by the BuildPiper
#       environment. Do NOT override it here to ensure events
#       appear correctly in the UI.
# ---------------------------------------------------------------

if [ "$DEBUG" = true ]; then
  set -x
fi

DOCKER_LINTER_OUTPUT_FILE="${DOCKER_LINTER_OUTPUT_FILE:-${ACTIVITY_SUB_TASK_CODE}_output.json}"

# ──────────────────────────────────────────────────────────────────────────────
# Configuration & Initialization
# ──────────────────────────────────────────────────────────────────────────────
WORKSPACE="${WORKSPACE:-/bp/workspace}"
CODEBASE_LOCATION="${WORKSPACE}/${CODEBASE_DIR}"
EXEC_DIR="/bp/execution_dir/${GLOBAL_TASK_ID}"
MERGED_JSON="docker_lint.json"
MERGED_CSV="docker_lint.csv"
RAW_JSON="docker_lint_raw.json"

SLEEP_DURATION="${SLEEP_DURATION:-0}"
HADOLINT_FAIL_THRESHOLD="${HADOLINT_FAIL_THRESHOLD:-error}"

logInfoMessage "> Starting step: docker_linter"
logInfoMessage "> Codebase location: ${CODEBASE_LOCATION}"

add_event "INITIALIZATION" "Successful" \
    "Docker linter step initialized" \
    "Codebase: ${CODEBASE_DIR} | Workspace: ${WORKSPACE}"

if [ "${SLEEP_DURATION}" -gt 0 ]; then
    logInfoMessage "> Sleeping for ${SLEEP_DURATION} second(s)..."
    sleep "$SLEEP_DURATION"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Dockerfile Path Resolution
# ──────────────────────────────────────────────────────────────────────────────
function dockerfile_path() {
  jq -r '.build_detail.dockerfile_path // empty' < /bp/data/environment_build
}

logInfoMessage "> Resolving Dockerfile path from configuration..."
DOCKERFILE_PATH=$(dockerfile_path)

if [[ -z "$DOCKERFILE_PATH" ]]; then
    logErrorMessage "> Dockerfile path not found in build configuration"
    add_event "DOCKERFILE_RESOLUTION" "Failed" \
        "Path not found in build details" \
        "dockerfile_path not set in build_detail"
    generateOutput "${ACTIVITY_SUB_TASK_CODE}" false \
        "Dockerfile path missing in configuration. Set 'dockerfile_path' in build_detail."
    saveTaskStatus 1 "${ACTIVITY_SUB_TASK_CODE}"
    exit 1
fi

if [[ "$DOCKERFILE_PATH" == *:* ]]; then
    DOCKERFILE_NAME="${DOCKERFILE_PATH%%:*}"
    DOCKERFILE_DIR="${DOCKERFILE_PATH##*:}"
else
    DOCKERFILE_NAME=$(basename "$DOCKERFILE_PATH")
    DOCKERFILE_DIR=$(dirname "$DOCKERFILE_PATH")
fi

DOCKERFILE_FULL_PATH="${DOCKERFILE_DIR}/${DOCKERFILE_NAME}"

logInfoMessage "> Dockerfile Name: ${DOCKERFILE_NAME}"
logInfoMessage "> Dockerfile Dir : ${DOCKERFILE_DIR}"
logInfoMessage "> Full Path      : ${DOCKERFILE_FULL_PATH}"

add_event "DOCKERFILE_RESOLUTION" "Successful" \
    "Path resolved successfully" \
    "Dockerfile: ${DOCKERFILE_FULL_PATH}"

# ──────────────────────────────────────────────────────────────────────────────
# Workspace Navigation & Validation
# ──────────────────────────────────────────────────────────────────────────────
logInfoMessage "> Navigating to codebase directory..."

cd "${CODEBASE_LOCATION}" || {
    logErrorMessage "> Failed to navigate to codebase directory: ${CODEBASE_LOCATION}"
    add_event "WORKSPACE_NAVIGATION" "Failed" \
        "Directory not found" \
        "Path: ${CODEBASE_LOCATION}"
    generateOutput "${ACTIVITY_SUB_TASK_CODE}" false "Codebase directory not found: ${CODEBASE_LOCATION}"
    saveTaskStatus 1 "${ACTIVITY_SUB_TASK_CODE}"
    exit 1
}

logInfoMessage "> Successfully navigated to: ${CODEBASE_LOCATION}"
add_event "WORKSPACE_NAVIGATION" "Successful" "Navigated to codebase" "Path: ${CODEBASE_LOCATION}"

if [[ ! -f "${DOCKERFILE_FULL_PATH}" ]]; then
    logErrorMessage "> Dockerfile not found at: ${CODEBASE_LOCATION}/${DOCKERFILE_FULL_PATH}"
    add_event "FILE_VALIDATION" "Failed" \
        "Dockerfile does not exist" \
        "Expected at: ${DOCKERFILE_FULL_PATH}"
    generateOutput "${ACTIVITY_SUB_TASK_CODE}" false "Dockerfile not found at path: ${DOCKERFILE_FULL_PATH}"
    saveTaskStatus 1 "${ACTIVITY_SUB_TASK_CODE}"
    exit 1
fi

logInfoMessage "> Dockerfile found. Size: $(stat -c%s "${DOCKERFILE_FULL_PATH}" 2>/dev/null || echo 'unknown') bytes"
add_event "FILE_VALIDATION" "Successful" "Dockerfile exists" "Path: ${DOCKERFILE_FULL_PATH}"

# ──────────────────────────────────────────────────────────────────────────────
# Tool Verification (Hadolint)
# ──────────────────────────────────────────────────────────────────────────────
logInfoMessage "> Verifying Hadolint installation..."

if ! command -v hadolint &> /dev/null; then
    logErrorMessage "> Hadolint binary not found in PATH"
    add_event "TOOL_VERIFICATION" "Failed" \
        "Hadolint not installed" \
        "Check base image dependencies"
    generateOutput "${ACTIVITY_SUB_TASK_CODE}" false "Hadolint binary not found. Install Hadolint or use a different Docker image."
    saveTaskStatus 1 "${ACTIVITY_SUB_TASK_CODE}"
    exit 1
fi

HADOLINT_VERSION=$(hadolint --version | head -1 || echo "unknown")
logInfoMessage "> Using Hadolint: ${HADOLINT_VERSION}"
add_event "TOOL_VERIFICATION" "Successful" "Binary found" "Version: ${HADOLINT_VERSION}"

# ──────────────────────────────────────────────────────────────────────────────
# Hadolint Execution
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "> Hadolint Execution Summary"
printf '+%-30s+%-50s+\n' '------------------------------' '--------------------------------------------------'
printf '| %-28s | %-48s |\n' "Parameter" "Value"
printf '+%-30s+%-50s+\n' '------------------------------' '--------------------------------------------------'
printf '| %-28s | %-48s |\n' "Codebase" "${CODEBASE_DIR}"
printf '+%-30s+%-50s+\n' '------------------------------' '--------------------------------------------------'
printf '| %-28s | %-48s |\n' "Dockerfile" "${DOCKERFILE_FULL_PATH}"
printf '+%-30s+%-50s+\n' '------------------------------' '--------------------------------------------------'
printf '| %-28s | %-48s |\n' "Threshold" "${HADOLINT_FAIL_THRESHOLD}"
printf '+%-30s+%-50s+\n' '------------------------------' '--------------------------------------------------'
echo ""

logInfoMessage "> Starting Hadolint scan..."
add_event "HADOLINT_SCAN_START" "Successful" "Initiating Dockerfile scan" "Target: ${DOCKERFILE_FULL_PATH}"

set +e
hadolint "${DOCKERFILE_FULL_PATH}" --format json > "${RAW_JSON}" 2>/tmp/hadolint.stderr
HADOLINT_EXIT_CODE=$?
set -e

if [[ -s /tmp/hadolint.stderr ]]; then
    logWarningMessage "> Hadolint stderr output:"
    cat /tmp/hadolint.stderr
fi

logInfoMessage "> Hadolint completed with exit code: ${HADOLINT_EXIT_CODE}"

if [[ ! -s "${RAW_JSON}" ]]; then
    logWarningMessage "> Hadolint returned empty output. Creating empty JSON array."
    echo "[]" > "${RAW_JSON}"
fi

chmod 644 "${RAW_JSON}"

# ──────────────────────────────────────────────────────────────────────────────
# Metrics Processing
# ──────────────────────────────────────────────────────────────────────────────
logInfoMessage "> Processing scan results..."

TOTAL_ISSUES=$(jq 'length' "${RAW_JSON}" 2>/dev/null || echo 0)
ERROR_COUNT=$(jq '[.[] | select(.level == "error")] | length' "${RAW_JSON}" 2>/dev/null || echo 0)
WARNING_COUNT=$(jq '[.[] | select(.level == "warning")] | length' "${RAW_JSON}" 2>/dev/null || echo 0)
INFO_COUNT=$(jq '[.[] | select(.level == "info")] | length' "${RAW_JSON}" 2>/dev/null || echo 0)
STYLE_COUNT=$(jq '[.[] | select(.level == "style")] | length' "${RAW_JSON}" 2>/dev/null || echo 0)

if [[ "$HADOLINT_EXIT_CODE" -eq 0 ]]; then
    add_event "HADOLINT_SCAN_RESULT" "Successful" "No issues detected" "Dockerfile is clean"
else
    add_event "HADOLINT_SCAN_RESULT" "Successful" "Issues detected" "Hadolint found ${TOTAL_ISSUES} issue(s)"
fi

echo ""
echo "> Scan Metrics Summary"
printf '+%-30s+%-50s+\n' '------------------------------' '--------------------------------------------------'
printf '| %-28s | %-48s |\n' "Metric" "Count"
printf '+%-30s+%-50s+\n' '------------------------------' '--------------------------------------------------'
printf '| %-28s | %-48s |\n' "Total Issues" "${TOTAL_ISSUES}"
printf '+%-30s+%-50s+\n' '------------------------------' '--------------------------------------------------'
printf '| %-28s | %-48s |\n' "Errors" "${ERROR_COUNT}"
printf '+%-30s+%-50s+\n' '------------------------------' '--------------------------------------------------'
printf '| %-28s | %-48s |\n' "Warnings" "${WARNING_COUNT}"
printf '+%-30s+%-50s+\n' '------------------------------' '--------------------------------------------------'
printf '| %-28s | %-48s |\n' "Info" "${INFO_COUNT}"
printf '+%-30s+%-50s+\n' '------------------------------' '--------------------------------------------------'
printf '| %-28s | %-48s |\n' "Style" "${STYLE_COUNT}"
printf '+%-30s+%-50s+\n' '------------------------------' '--------------------------------------------------'
echo ""

# Display issues in tabular format        
if [[ ${TOTAL_ISSUES} -gt 0 ]]; then
    logInfoMessage "> Displaying Lint Issues Table:"
    echo "Rule,Level,Line,Message" > /tmp/hadolint_display.csv
    jq -r '
        .[] |
        [
            (.code // "UNKNOWN"),
            (.level // "unknown"),
            (.line // 0 | tostring),
            (.message // "" | gsub("\n"; " ") | gsub("\r"; "") | gsub("\""; "'\''"))
        ] | @csv
    ' "${RAW_JSON}" | sed 's/"//g' >> /tmp/hadolint_display.csv
    python3 /opt/buildpiper/shell-functions/print_table.py /tmp/hadolint_display.csv
fi

# ──────────────────────────────────────────────────────────────────────────────
# Report Generation
# ──────────────────────────────────────────────────────────────────────────────
logInfoMessage "> Generating CSV and JSON reports..."

echo "rule,level,message,line,column" > "${MERGED_CSV}"
jq -r '
    .[] |
    [
        (.code // "UNKNOWN"),
        (.level // "unknown"),
        (.message // "" | gsub("\n"; " ") | gsub("\r"; "") | gsub("\""; "'\''") ),
        (.line // 0),
        (.column // 0)
    ] | @csv
' "${RAW_JSON}" >> "${MERGED_CSV}" 2>/dev/null || {
    logWarningMessage "> Failed to generate CSV from JSON. Using empty CSV."
}
chmod 644 "${MERGED_CSV}"

CSV_LINE_COUNT=$(wc -l < "${MERGED_CSV}" 2>/dev/null || echo 1)
add_event "REPORT_GENERATION" "Successful" "Reports created" "CSV lines: ${CSV_LINE_COUNT}"

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
            error: ($issues[0] | [.[] | select(.level == "error")] | length),
            warning: ($issues[0] | [.[] | select(.level == "warning")] | length),
            info: ($issues[0] | [.[] | select(.level == "info")] | length),
            style: ($issues[0] | [.[] | select(.level == "style")] | length)
        }
    }' > "${MERGED_JSON}"
chmod 644 "${MERGED_JSON}"

logInfoMessage "> Copying reports to execution directory: ${EXEC_DIR}/"
mkdir -p "${EXEC_DIR}"
cp -f "${MERGED_JSON}" "${EXEC_DIR}/" || logWarningMessage "> Failed to copy JSON report"
cp -f "${MERGED_CSV}" "${EXEC_DIR}/" || logWarningMessage "> Failed to copy CSV report"

# ──────────────────────────────────────────────────────────────────────────────
# Threshold Validation & Final Status
# ──────────────────────────────────────────────────────────────────────────────
logInfoMessage "> Evaluating against failure threshold: ${HADOLINT_FAIL_THRESHOLD}"
TASK_STATUS="success"
FAILURE_REASON=""

case "${HADOLINT_FAIL_THRESHOLD}" in
    error)
        if [[ ${ERROR_COUNT} -gt 0 ]]; then
            TASK_STATUS="failed"
            FAILURE_REASON="Found ${ERROR_COUNT} error-level issue(s)"
        fi
        ;;
    warning)
        if [[ ${ERROR_COUNT} -gt 0 ]] || [[ ${WARNING_COUNT} -gt 0 ]]; then
            TASK_STATUS="failed"
            FAILURE_REASON="Found ${ERROR_COUNT} error(s) and ${WARNING_COUNT} warning(s)"
        fi
        ;;
    info)
        if [[ ${ERROR_COUNT} -gt 0 ]] || [[ ${WARNING_COUNT} -gt 0 ]] || [[ ${INFO_COUNT} -gt 0 ]]; then
            TASK_STATUS="failed"
            FAILURE_REASON="Found ${ERROR_COUNT} error(s), ${WARNING_COUNT} warning(s), ${INFO_COUNT} info issue(s)"
        fi
        ;;
    style)
        if [[ ${TOTAL_ISSUES} -gt 0 ]]; then
            TASK_STATUS="failed"
            FAILURE_REASON="Found ${TOTAL_ISSUES} total issue(s) including style violations"
        fi
        ;;
    ignore|none)
        TASK_STATUS="success"
        logInfoMessage "> Threshold set to 'ignore' — passing pipeline regardless of issues"
        ;;
    *)
        logWarningMessage "> Unknown threshold '${HADOLINT_FAIL_THRESHOLD}' — defaulting to 'error'"
        if [[ ${ERROR_COUNT} -gt 0 ]]; then
            TASK_STATUS="failed"
            FAILURE_REASON="Found ${ERROR_COUNT} error-level issue(s)"
        fi
        ;;
esac

if [[ "${TASK_STATUS}" == "success" ]]; then
    add_event "THRESHOLD_VALIDATION" "Successful" "Scan passed" "Issues within acceptable threshold"
else
    add_event "THRESHOLD_VALIDATION" "Failed" "Threshold breached" "${FAILURE_REASON}"
fi

# ──────────────────────────────────────────────────────────────────────────────
# BuildPiper Output payload
# ──────────────────────────────────────────────────────────────────────────────
MESSAGE="Dockerfile linting completed. Total issues: ${TOTAL_ISSUES} (Errors: ${ERROR_COUNT}, Warnings: ${WARNING_COUNT})"

if [[ "${TASK_STATUS}" == "success" ]]; then
    TASK_STATUS_INT=0
    FINAL_MESSAGE="${MESSAGE}"
    STATUS_BOOL="true"
else
    TASK_STATUS_INT=1
    FINAL_MESSAGE="${FAILURE_REASON}. See report for details."
    STATUS_BOOL="false"
    logErrorMessage "> ${FINAL_MESSAGE}"
fi

jq -n \
  --argjson status_bool "$STATUS_BOOL" \
  --arg final_reason "$FINAL_MESSAGE" \
  --arg final_message "$FINAL_MESSAGE" \
  --arg dockerfile "$DOCKERFILE_FULL_PATH" \
  --argjson total "$TOTAL_ISSUES" \
  --argjson errors "$ERROR_COUNT" \
  --argjson warnings "$WARNING_COUNT" \
  --argjson info "$INFO_COUNT" \
  --argjson style "$STYLE_COUNT" \
  '{
    build: {
      status: $status_bool,
      reason: $final_reason,
      message: $final_message,
      current_error: (if $status_bool == "false" then $final_reason else "" end)
    },
    output_vars: {
      docker_lint: {
        status: $status_bool,
        reason: $final_reason,
        message: $final_message,
        scan: { dockerfile: $dockerfile },
        results: {
          total: $total,
          errors: $errors,
          warnings: $warnings,
          info: $info,
          style: $style
        },
        current_error: (if $status_bool == "false" then $final_reason else "" end)
      }
    }
  }' > "${EXEC_DIR}/${DOCKER_LINTER_OUTPUT_FILE}"

logInfoMessage "> Output JSON written to ${EXEC_DIR}/${DOCKER_LINTER_OUTPUT_FILE}"

if [ $TASK_STATUS_INT -eq 0 ]; then
    logInfoMessage "> Linter step passed"
    generateOutput ${ACTIVITY_SUB_TASK_CODE} true "$FINAL_MESSAGE"
elif [ "${VALIDATION_FAILURE_ACTION:-FAILURE}" == "FAILURE" ]; then
    logErrorMessage "> Linter step FAILED"
    generateOutput ${ACTIVITY_SUB_TASK_CODE} false "$FINAL_MESSAGE"
    saveTaskStatus 1 "${ACTIVITY_SUB_TASK_CODE}"
    exit 1
else
    logWarningMessage "> Linter step failed, but configured as NON-BLOCKING"
    add_event "NON_BLOCKING_WARNING" "Successful" "Pipeline continuing" "VALIDATION_FAILURE_ACTION is not FAILURE"
    generateOutput ${ACTIVITY_SUB_TASK_CODE} false "$FINAL_MESSAGE"
fi

saveTaskStatus $TASK_STATUS_INT "${ACTIVITY_SUB_TASK_CODE}"

logInfoMessage "> Dockerfile Linting Complete (Status: ${TASK_STATUS})"

if [[ "${TASK_STATUS}" == "failed" ]]; then
    exit 1
fi

exit 0