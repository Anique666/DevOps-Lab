FROM jenkins/jenkins:lts-jdk17

USER root

# The Jenkins container drives the host Docker daemon through the mounted
# socket, so it needs the Docker CLI. Python is not required for this pipeline.
RUN apt-get update \
    && apt-get install -y --no-install-recommends docker.io curl \
    && rm -rf /var/lib/apt/lists/*

USER jenkins
