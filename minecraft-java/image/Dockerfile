# syntax=docker/dockerfile:1
# ionnet-gss-minecraft-server:java<N>: the base image plus a Temurin JRE. One tag per Java line: java8, java17,
# java21, java25 (image.yml lists them; the images workflow passes JAVA). game.yml picks it with
# `image: …:java{{vars.java}}`.
# The JRE is copied from the official eclipse-temurin image of that line (the same Adoptium release tarball,
# checksum-verified by that image's build), so there is no apt repository or key to manage here.

ARG BASE=ghcr.io/ionnet-dev/ionnet-gss-base:latest
ARG JAVA=21
FROM eclipse-temurin:${JAVA}-jre AS jre

FROM ${BASE}
ARG JAVA
COPY --from=jre /opt/java/openjdk /opt/java/openjdk
ENV JAVA_HOME=/opt/java/openjdk \
  PATH=/opt/java/openjdk/bin:$PATH
RUN java -version 2>&1 | tee /dev/stderr | grep -Eq "version \"(1\.)?${JAVA}[._\"]"
LABEL dev.ionnet.gss.java="${JAVA}"
LABEL org.opencontainers.image.source="https://github.com/ionnet-dev/ionnet-gss-games" \
  org.opencontainers.image.description="Ionnet GSS Minecraft: Java Edition server image (Temurin JRE ${JAVA})"
