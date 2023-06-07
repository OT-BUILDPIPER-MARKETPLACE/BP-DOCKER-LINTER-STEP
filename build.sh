#!/bin/bash

source functions.sh
source log-functions.sh
source str-functions.sh
source file-functions.sh
source aws-functions.sh

logInfoMessage "I'll scan the Dockerfile  available at [$WORKSPACE/$CODEBASE_DIR]"

cd  $WORKSPACE/$CODEBASE_DIR

if [ -d "reports" ]; then
    true
else
    mkdir reports 
fi

if [ -f "$DOCKERFILE_PATH" ]
then
  hadolint $DOCKERFILE_PATH
  cd reports
  hadolint $DOCKERFILE_PATH --format json > docker_lint.json 2> /dev/null
else
  logInfoMessage "Please check Dockerfile is not present"
fi

if [ $? -eq 0 ]
then
  logInfoMessage "Congratulations docker lint scan succeeded!!!"
  generateOutput docker_lint true "Congratulations docker lint scan succeeded!!!"
elif [ $VALIDATION_FAILURE_ACTION == "FAILURE" ]
  then
    logErrorMessage "Please check docker lint scan failed!!!"
    generateOutput ${ACTIVITY_SUB_TASK_CODE} false "Please check docker lint scan failed!!!"
    exit 1
   else
    logWarningMessage "Please check docker lint scan failed!!!"
    generateOutput ${ACTIVITY_SUB_TASK_CODE} true "Please check docker lint scan failed!!!"
fi