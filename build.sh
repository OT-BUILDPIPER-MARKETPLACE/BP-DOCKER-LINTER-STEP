#!/bin/sh
source functions.sh

logInfoMessage "I'll scan the Dockerfile  available at [${WORKSPACE}${CODEBASE_DIR}]"

sleep  $SLEEP_DURATION
cd  $WORKSPACE/${CODEBASE_DIR}

hadolint ${DOCKERFILE_PATH}
