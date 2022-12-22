#!/bin/bash
source functions.sh
source log-functions.sh

logInfoMessage "I'll scan the Dockerfile  available at [${WORKSPACE}${CODEBASE_DIR}]"

sleep  $SLEEP_DURATION
cd  $WORKSPACE/${CODEBASE_DIR}

hadolint ${DOCKERFILE_PATH}

if [ $? -eq 0 ]
then
  logInfoMessage "Congratulations docker lint scan succeeded!!!"
  generateOutput mvn_execute true "Congratulations docker lint scan succeeded!!!"
elif [ $VALIDATION_FAILURE_ACTION == "FAILURE" ]
  then
    logErrorMessage "Please check docker lint scan failed!!!"
    generateOutput ${ACTIVITY_SUB_TASK_CODE} false "Please check docker lint scan failed!!!"
    exit 1
   else
    logWarningMessage "Please check docker lint scan failed!!!"
    generateOutput ${ACTIVITY_SUB_TASK_CODE} true "Please check docker lint scan failed!!!"
fi
