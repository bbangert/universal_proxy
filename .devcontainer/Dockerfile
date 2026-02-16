FROM ubuntu:24.04

# Avoid prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    avahi-utils \
    file \
    automake \
    autoconf \
    git \
    curl \
    wget \
    unzip \
    pkg-config \
    libssl-dev \
    libncurses5-dev \
    libmnl-dev \
    protobuf-compiler \
    squashfs-tools \
    ssh-askpass \
    inotify-tools \
    libarchive-dev \
    libconfuse-dev \
    && rm -rf /var/lib/apt/lists/*

# Install fwup from GitHub releases (not in Ubuntu repos)
RUN FWUP_VERSION="1.10.2" && \
    curl -fsSL "https://github.com/fwup-home/fwup/releases/download/v${FWUP_VERSION}/fwup_${FWUP_VERSION}_amd64.deb" -o /tmp/fwup.deb && \
    dpkg -i /tmp/fwup.deb && \
    rm /tmp/fwup.deb

# Install mise
RUN curl https://mise.run | sh
ENV PATH="/root/.local/bin:${PATH}"

# Activate mise in shell
RUN echo 'eval "$(mise activate bash)"' >> ~/.bashrc \
    && echo 'eval "$(mise activate zsh)"' >> ~/.zshrc

# Set up mise to trust the project directory
RUN mise settings set experimental true

WORKDIR /workspace
