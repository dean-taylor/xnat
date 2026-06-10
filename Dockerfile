# XNAT runtime image
# Built by .github/workflows/build-publish.yml. Expects:
#   ./docker-context/xnat.war       — WAR with logback already rewritten to
#                                     ConsoleAppender by the workflow.
#   ./docker/entrypoint.sh          — runtime helper (timezone handling).
#   ./docker/make-xnat-config.sh    — generates default xnat-conf.properties.

FROM gradle:9-jdk21 AS builder
WORKDIR /app

# Copy files required to resolve dependencies
COPY gradlew settings.gradle* build.gradle* /app/
COPY gradle /app/gradle


# Download and cache depencencies
RUN ./gradlew dependencies --no-daemon || true

# Copy source and build
COPY ./ /app/

RUN ./gradlew build -x test
RUN ./gradlew :xnat-web:war

# Expand the WAR into webapps/ROOT/. The workflow has already
# rewritten WEB-INF/classes/logback.xml to ConsoleAppender via
# scripts/edit-log.py, so no further log config patching needed here.
RUN <<EOT
  apt-get update
  apt-get -y install \
    unzip
  mkdir -p /webapps
  unzip -o -d /webapps xnat-web/build/libs/xnat-web-*.war
EOT



FROM tomcat:9-jdk21-temurin
# -----------------------------------------------------------------------------
# Build-time arguments. All have safe DEFAULT values intended for dev only;
# any production deployment MUST override the *_PASSWORD / *_USERNAME / *_URL
# entries at runtime via `docker run -e ...` or the orchestrator's secrets.
# -----------------------------------------------------------------------------
ARG XNAT_ROOT=/data/xnat
ARG XNAT_HOME=/data/xnat/home
ARG XNAT_DATASOURCE_DRIVER=org.postgresql.Driver
ARG XNAT_DATASOURCE_URL=jdbc:postgresql://xnat-postgresql/xnat
ARG XNAT_DATASOURCE_USERNAME=xnat
ARG XNAT_SMTP_ENABLED=false
ARG TOMCAT_XNAT_FOLDER=ROOT
ARG TOMCAT_XNAT_FOLDER_PATH=${CATALINA_HOME}/webapps/${TOMCAT_XNAT_FOLDER}
ARG XNAT_ACTIVEMQ=xnat-activemq

# Container-aware heap sizing. Percentages refer to the cgroup limit;
# they're harmless under plain `docker run` as well (default 75% MaxRAM).
ENV CATALINA_OPTS="-XX:+UseContainerSupport \
    -XX:InitialRAMPercentage=50.0 \
    -XX:MinRAMPercentage=50.0 \
    -XX:MaxRAMPercentage=66.0 \
    -Dxnat.home=${XNAT_HOME}"

ENV XNAT_HOME=${XNAT_HOME} \
    XNAT_DATASOURCE_USERNAME=${XNAT_DATASOURCE_USERNAME}

# -----------------------------------------------------------------------------
# Helper scripts. Copied from ./docker/ in the build context.
# -----------------------------------------------------------------------------
COPY --chmod=0755 docker/entrypoint.sh       /usr/local/bin/entrypoint.sh

# XNAT directory layout — pre-created so a fresh container has somewhere
# to write before any volume is mounted. Most of these are intended to
# be replaced by volume mounts in production.
RUN <<EOT
  rm -rf ${CATALINA_HOME}/webapps/*
  mkdir -p \
        ${TOMCAT_XNAT_FOLDER_PATH} \
        ${XNAT_HOME}/config \
        ${XNAT_HOME}/logs \
        ${XNAT_HOME}/plugins \
        ${XNAT_HOME}/work \
        ${XNAT_ROOT}/archive \
        ${XNAT_ROOT}/build \
        ${XNAT_ROOT}/cache \
        ${XNAT_ROOT}/ftp \
        ${XNAT_ROOT}/pipeline \
        ${XNAT_ROOT}/prearchive
EOT

COPY --from=builder /webapps/ ${TOMCAT_XNAT_FOLDER_PATH}

VOLUME ["/data/xnat"]
EXPOSE 8080

ENTRYPOINT ["entrypoint.sh"]
CMD ["catalina.sh", "run"]
