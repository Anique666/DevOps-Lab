FROM jenkins/jenkins:lts-jdk17

USER root

# python3-venv is a separate Debian package; pip alone is not enough.
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 python3-venv python3-pip \
    && rm -rf /var/lib/apt/lists/*

USER jenkins
