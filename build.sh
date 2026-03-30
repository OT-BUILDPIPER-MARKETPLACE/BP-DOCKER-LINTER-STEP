#!/bin/bash

source /opt/buildpiper/shell-functions/functions.sh
source /opt/buildpiper/shell-functions/log-functions.sh
source /opt/buildpiper/shell-functions/file-functions.sh
source /opt/buildpiper/shell-functions/str-functions.sh
source /opt/buildpiper/shell-functions/getDataFile.sh

if [ "$DEBUG" = true ]; then
  set -x
fi

###############################################
### EVENTS TRACKING
###############################################
EVENTS='{}'

add_event() {
  local key="${1:-}"
  local status="${2:-}"
  local reason="${3:-}"
  local message="${4:-}"

  if [ -z "$key" ] || [ -z "$status" ]; then
    logErrorMessage "add_event requires at least 'key' and 'status' parameters"
    return 1
  fi

  key="$(echo "$key" | tr '_' ' ' | tr '-' ' ' | tr '[:upper:]' '[:lower:]')"

  EVENTS=$(jq \
    --arg k "$key" \
    --arg status "$status" \
    --arg reason "$reason" \
    --arg message "$message" \
    '. + {($k): {status: $status, reason: $reason, message: $message}}' \
    <<< "$EVENTS") || {
    logErrorMessage "Failed to add event to EVENTS JSON"
    return 1
  }
}

###############################################
### OUTPUT FILE
###############################################
DOCKER_LINTER_OUTPUT_FILE="${DOCKER_LINTER_OUTPUT_FILE:-${ACTIVITY_SUB_TASK_CODE}_output.json}"

# ──────────────────────────────────────────────────────────────────────────────
# Configuration
# ──────────────────────────────────────────────────────────────────────────────
CODEBASE_LOCATION="${WORKSPACE}/${CODEBASE_DIR}"
EXEC_DIR="/bp/execution_dir/${GLOBAL_TASK_ID}"
MERGED_JSON="docker_lint.json"
MERGED_CSV="docker_lint.csv"
RAW_JSON="docker_lint_raw.json"

SLEEP_DURATION="${SLEEP_DURATION:-0}"
HADOLINT_FAIL_THRESHOLD="${HADOLINT_FAIL_THRESHOLD:-error}"

sleep "$SLEEP_DURATION"

# ──────────────────────────────────────────────────────────────────────────────
# Get Dockerfile path from build config
# ──────────────────────────────────────────────────────────────────────────────
function dockerfile_path() {
  jq -r '.build_detail.dockerfile_path // empty' < /bp/data/environment_build
}

DOCKERFILE_PATH=$(dockerfile_path)

if [[ -z "$DOCKERFILE_PATH" ]]; then
    logErrorMessage "Dockerfile path not found in build configuration."
    add_event "dockerfile path" "Failed" "Path not found" "dockerfile_path not set in build_detail"
    generateOutput "${ACTIVITY_SUB_TASK_CODE}" false \
        "Dockerfile path missing in configuration. Set 'dockerfile_path' in build_detail."
    saveTaskStatus 1 "${ACTIVITY_SUB_TASK_CODE}"
    exit 1
fi

logInfoMessage "Dockerfile Path from config: ${DOCKERFILE_PATH}"

# ──────────────────────────────────────────────────────────────────────────────
# Parse Dockerfile name and directory
# ──────────────────────────────────────────────────────────────────────────────
if [[ "$DOCKERFILE_PATH" == *:* ]]; then
    DOCKERFILE_NAME="${DOCKERFILE_PATH%%:*}"
    DOCKERFILE_DIR="${DOCKERFILE_PATH##*:}"
else
    DOCKERFILE_NAME=$(basename "$DOCKERFILE_PATH")
    DOCKERFILE_DIR=$(dirname "$DOCKERFILE_PATH")
fi

DOCKERFILE_FULL_PATH="${DOCKERFILE_DIR}/${DOCKERFILE_NAME}"

logInfoMessage "Detected Dockerfile Name: ${DOCKERFILE_NAME}"
logInfoMessage "Detected Dockerfile Directory: ${DOCKERFILE_DIR}"
logInfoMessage "Full Dockerfile Path: ${DOCKERFILE_FULL_PATH}"

add_event "dockerfile path" "Successful" "Path resolved" "Dockerfile resolved to ${DOCKERFILE_FULL_PATH}"

# ──────────────────────────────────────────────────────────────────────────────
# Validate Dockerfile exists
# ──────────────────────────────────────────────────────────────────────────────
logInfoMessage "=============================================================="
logInfoMessage " Starting Dockerfile Linting (Hadolint)"
logInfoMessage "=============================================================="
logInfoMessage " Codebase location : ${CODEBASE_LOCATION}"
logInfoMessage " Dockerfile path   : ${DOCKERFILE_FULL_PATH}"
logInfoMessage " Fail threshold    : ${HADOLINT_FAIL_THRESHOLD}"
logInfoMessage "=============================================================="

cd "${CODEBASE_LOCATION}" || {
    logErrorMessage "Failed to change directory to: ${CODEBASE_LOCATION}"
    add_event "codebase directory" "Failed" "Directory not found" "${CODEBASE_LOCATION} does not exist"
    generateOutput "${ACTIVITY_SUB_TASK_CODE}" false \
        "Codebase directory not found: ${CODEBASE_LOCATION}"
    saveTaskStatus 1 "${ACTIVITY_SUB_TASK_CODE}"
    exit 1
}

add_event "codebase directory" "Successful" "Directory found" "Changed to ${CODEBASE_LOCATION}"

if [[ ! -f "${DOCKERFILE_FULL_PATH}" ]]; then
    logErrorMessage "Dockerfile not found at: ${CODEBASE_LOCATION}/${DOCKERFILE_FULL_PATH}"
    add_event "dockerfile found" "Failed" "File not found" "Dockerfile not found at ${DOCKERFILE_FULL_PATH}"
    generateOutput "${ACTIVITY_SUB_TASK_CODE}" false \
        "Dockerfile not found at path: ${DOCKERFILE_FULL_PATH}"
    saveTaskStatus 1 "${ACTIVITY_SUB_TASK_CODE}"
    exit 1
fi

logInfoMessage "Dockerfile found. Size: $(stat -c%s "${DOCKERFILE_FULL_PATH}" 2>/dev/null || echo 'unknown') bytes"
add_event "dockerfile found" "Successful" "File exists" "Dockerfile found at ${DOCKERFILE_FULL_PATH}"

# ──────────────────────────────────────────────────────────────────────────────
# Check Hadolint is installed
# ──────────────────────────────────────────────────────────────────────────────
if ! command -v hadolint &> /dev/null; then
    logErrorMessage "Hadolint binary not found. Please ensure Hadolint is installed."
    add_event "hadolint installation" "Failed" "Binary not found" "hadolint not available in PATH"
    generateOutput "${ACTIVITY_SUB_TASK_CODE}" false \
        "Hadolint binary not found. Install Hadolint or use a different Docker image."
    saveTaskStatus 1 "${ACTIVITY_SUB_TASK_CODE}"
    exit 1
fi

HADOLINT_VERSION=$(hadolint --version | head -1 || echo "unknown")
logInfoMessage "Using Hadolint: ${HADOLINT_VERSION}"
add_event "hadolint installation" "Successful" "Binary found" "${HADOLINT_VERSION}"

# ──────────────────────────────────────────────────────────────────────────────
# Run Hadolint
# ──────────────────────────────────────────────────────────────────────────────
logInfoMessage "Running hadolint on: ${DOCKERFILE_FULL_PATH}"

set +e
hadolint "${DOCKERFILE_FULL_PATH}" --format json > "${RAW_JSON}" 2>/tmp/hadolint.stderr
HADOLINT_EXIT_CODE=$?
set -e

if [[ -s /tmp/hadolint.stderr ]]; then
    logWarningMessage "Hadolint stderr output:"
    cat /tmp/hadolint.stderr
fi

logInfoMessage "Hadolint exit code: ${HADOLINT_EXIT_CODE}"

# ──────────────────────────────────────────────────────────────────────────────
# Handle empty output
# ──────────────────────────────────────────────────────────────────────────────
if [[ ! -s "${RAW_JSON}" ]]; then
    logWarningMessage "Hadolint returned empty output. Creating empty JSON array."
    echo "[]" > "${RAW_JSON}"
fi

chmod 644 "${RAW_JSON}"

# ──────────────────────────────────────────────────────────────────────────────
# Count issues by severity
# ──────────────────────────────────────────────────────────────────────────────
TOTAL_ISSUES=$(jq 'length' "${RAW_JSON}" 2>/dev/null || echo 0)
ERROR_COUNT=$(jq '[.[] | select(.level == "error")] | length' "${RAW_JSON}" 2>/dev/null || echo 0)
WARNING_COUNT=$(jq '[.[] | select(.level == "warning")] | length' "${RAW_JSON}" 2>/dev/null || echo 0)
INFO_COUNT=$(jq '[.[] | select(.level == "info")] | length' "${RAW_JSON}" 2>/dev/null || echo 0)
STYLE_COUNT=$(jq '[.[] | select(.level == "style")] | length' "${RAW_JSON}" 2>/dev/null || echo 0)

if [[ "$HADOLINT_EXIT_CODE" -eq 0 ]]; then
    add_event "hadolint scan" "Successful" "No issues detected" "Hadolint completed — Dockerfile is clean"
else
    add_event "hadolint scan" "Successful" "Issues detected" "Hadolint found ${TOTAL_ISSUES} issue(s)"
fi

add_event "lint results" "Successful" "Issues counted" "Total=${TOTAL_ISSUES} Errors=${ERROR_COUNT} Warnings=${WARNING_COUNT} Info=${INFO_COUNT} Style=${STYLE_COUNT}"

logInfoMessage "=============================================================="
logInfoMessage " Linting Results"
logInfoMessage "=============================================================="
logInfoMessage " Total issues  : ${TOTAL_ISSUES}"
logInfoMessage " Errors        : ${ERROR_COUNT}"
logInfoMessage " Warnings      : ${WARNING_COUNT}"
logInfoMessage " Info          : ${INFO_COUNT}"
logInfoMessage " Style         : ${STYLE_COUNT}"
logInfoMessage "=============================================================="

# ──────────────────────────────────────────────────────────────────────────────
# Display issues in tabular format        
# ──────────────────────────────────────────────────────────────────────────────
if [[ ${TOTAL_ISSUES} -gt 0 ]]; then
    logInfoMessage "Displaying Lint Issues:"
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
# Generate CSV report
# ──────────────────────────────────────────────────────────────────────────────
logInfoMessage "Generating CSV report..."

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
    logWarningMessage "Failed to generate CSV from JSON. Using empty CSV."
}

chmod 644 "${MERGED_CSV}"

CSV_LINE_COUNT=$(wc -l < "${MERGED_CSV}" 2>/dev/null || echo 1)
logInfoMessage "CSV report generated with ${CSV_LINE_COUNT} lines (including header)."
add_event "generate csv report" "Successful" "CSV created" "Report written with ${CSV_LINE_COUNT} lines"

# ──────────────────────────────────────────────────────────────────────────────
# Generate final JSON report
# ──────────────────────────────────────────────────────────────────────────────
logInfoMessage "Building final JSON report..."

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

# ──────────────────────────────────────────────────────────────────────────────
# Copy reports to execution directory
# ──────────────────────────────────────────────────────────────────────────────
logInfoMessage "Copying reports to execution directory: ${EXEC_DIR}/"

mkdir -p "${EXEC_DIR}"
cp -f "${MERGED_JSON}" "${EXEC_DIR}/" || logWarningMessage "Failed to copy JSON report"
cp -f "${MERGED_CSV}" "${EXEC_DIR}/" || logWarningMessage "Failed to copy CSV report"

logInfoMessage "Reports saved:"
logInfoMessage " - ${EXEC_DIR}/${MERGED_JSON}"
logInfoMessage " - ${EXEC_DIR}/${MERGED_CSV}"

# ──────────────────────────────────────────────────────────────────────────────
# Determine final task status based on threshold
# ──────────────────────────────────────────────────────────────────────────────
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
        logInfoMessage "Threshold set to '${HADOLINT_FAIL_THRESHOLD}' — ignoring all lint issues."
        ;;
    *)
        logWarningMessage "Unknown threshold '${HADOLINT_FAIL_THRESHOLD}'. Defaulting to 'error' level."
        if [[ ${ERROR_COUNT} -gt 0 ]]; then
            TASK_STATUS="failed"
            FAILURE_REASON="Found ${ERROR_COUNT} error-level issue(s)"
        fi
        ;;
esac

if [[ "${TASK_STATUS}" == "success" ]]; then
    add_event "threshold check" "Successful" "Within threshold" "No issues exceeded ${HADOLINT_FAIL_THRESHOLD} threshold"
else
    add_event "threshold check" "Failed" "Threshold breached" "${FAILURE_REASON}"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Build error events and write structured output JSON
# ──────────────────────────────────────────────────────────────────────────────
MESSAGE="Dockerfile linting completed. Total issues: ${TOTAL_ISSUES} (Errors: ${ERROR_COUNT}, Warnings: ${WARNING_COUNT})"

if [[ "${TASK_STATUS}" == "success" ]]; then
    TASK_STATUS_INT=0
    FINAL_MESSAGE="${MESSAGE}"
else
    TASK_STATUS_INT=1
    FINAL_MESSAGE="${FAILURE_REASON}. See report for details."
    logErrorMessage "${FINAL_MESSAGE}"
fi

ERROR_EVENTS=$(echo "$EVENTS" | jq '[to_entries[] | select(.value.status == "Failed") | .key]')

if [[ $TASK_STATUS_INT -eq 0 ]]; then
    STATUS_BOOL="true"
else
    STATUS_BOOL="false"
fi

jq -n \
  --argjson events "$EVENTS" \
  --argjson error_events "$ERROR_EVENTS" \
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
      events: $events,
      current_error: (if $status_bool == "false" then $final_reason else "" end),
      error_events: $error_events
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
        current_error: (if $status_bool == "false" then $final_reason else "" end),
        error_events: $error_events
      }
    }
  }' > "${EXEC_DIR}/${DOCKER_LINTER_OUTPUT_FILE}"

logInfoMessage "Output JSON written to ${EXEC_DIR}/${DOCKER_LINTER_OUTPUT_FILE}"

# ──────────────────────────────────────────────────────────────────────────────
# Generate BuildPiper output
# ──────────────────────────────────────────────────────────────────────────────
if [ $TASK_STATUS_INT -eq 0 ]; then
    logInfoMessage "Congratulations! Dockerfile linting passed."
    generateOutput ${ACTIVITY_SUB_TASK_CODE} true "$FINAL_MESSAGE"
elif [ "${VALIDATION_FAILURE_ACTION:-FAILURE}" == "FAILURE" ]; then
    logErrorMessage "Dockerfile linting FAILED. Stopping pipeline."
    generateOutput ${ACTIVITY_SUB_TASK_CODE} false "$FINAL_MESSAGE"
    saveTaskStatus 1 "${ACTIVITY_SUB_TASK_CODE}"
    exit 1
else
    logWarningMessage "Dockerfile linting failed, but the step is configured as NON-BLOCKING (warning mode).

  If you want the pipeline to FAIL on issues:
  - Go to job template settings
  - Set VALIDATION_FAILURE_ACTION = FAILURE

  Current setting allows pipeline to continue."
    add_event "validation mode" "Successful" "Non-blocking validation" "Scan failed but pipeline continued because VALIDATION_FAILURE_ACTION is not FAILURE"
    generateOutput ${ACTIVITY_SUB_TASK_CODE} false "$FINAL_MESSAGE"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Save final task status
# ──────────────────────────────────────────────────────────────────────────────
saveTaskStatus $TASK_STATUS_INT "${ACTIVITY_SUB_TASK_CODE}"

logInfoMessage "=============================================================="
logInfoMessage " Dockerfile Linting Complete"
logInfoMessage " Status: ${TASK_STATUS}"
logInfoMessage "=============================================================="

if [[ "${TASK_STATUS}" == "failed" ]]; then
    exit 1
fi

exit 0