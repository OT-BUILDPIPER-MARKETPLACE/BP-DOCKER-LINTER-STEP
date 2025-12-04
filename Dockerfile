FROM hadolint/hadolint:latest-alpine

RUN addgroup -g 65522 buildpiper && \
    adduser -u 65522 -G buildpiper -D -h /home/buildpiper buildpiper && \
    mkdir -p \
      /app \
      /bp/data \
      /bp/execution_dir \
      /bp/workspace \
      /opt/buildpiper/shell-functions \
      /opt/buildpiper/data \
      /home/buildpiper/reports \
      /usr/local/bin \
      /src/reports \
    && chown -R buildpiper:buildpiper \
      /app /bp /opt /home/buildpiper /src /usr/local/bin /tmp

RUN apk add --no-cache bash jq curl git gettext libintl

ENV SLEEP_DURATION=5s

WORKDIR /app

COPY --chown=buildpiper:buildpiper build.sh ./build.sh
COPY --chown=buildpiper:buildpiper BP-BASE-SHELL-STEPS/ /opt/buildpiper/shell-functions/
COPY --chown=buildpiper:buildpiper BP-BASE-SHELL-STEPS/data /opt/buildpiper/data

RUN chmod +x /app/build.sh

USER buildpiper

ENTRYPOINT ["./build.sh"]

