FROM hadolint/hadolint:latest-alpine

RUN apk add --no-cache --upgrade bash
RUN apk add jq

COPY build.sh .
COPY BP-BASE-SHELL-STEPS/functions.sh .

ENV ACTIVITY_SUB_TASK_CODE BP-DOCKER-LINTER
ENV SLEEP_DURATION 5s
ENV VALIDATION_FAILURE_ACTION WARNING
ENV DOCKERFILE_PATH "Dockerfile"

ENTRYPOINT [ "./build.sh" ]