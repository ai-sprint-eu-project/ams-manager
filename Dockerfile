# syntax=docker/dockerfile:1
FROM alpine:3.14
RUN apk add --no-cache jq tar coreutils gawk grep bash gomplate curl kubectl helm
COPY executables/* /usr/local/bin/
WORKDIR /home

LABEL org.opencontainers.image.title="Monitoring Manager" \
    org.opencontainers.image.description="AI-SPRINT Monitoring Subsystem (AMS) Monitoring Manager" \
    org.opencontainers.image.version="1.0" \
    org.opencontainers.image.authors="Michał Soczewka" \
    org.opencontainers.image.licenses="MIT" \
    org.opencontainers.image.url="https://github.com/ai-sprint-eu-project/monitoring-subsystem" \
    org.opencontainers.image.documentation="https://github.com/ai-sprint-eu-project/monitoring-subsystem"

ADD scripts ./
CMD ["./initial_setup.sh"]
