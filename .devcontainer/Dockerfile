FROM ubuntu:latest

# Install dependencies
RUN apt-get update && apt-get install -y \
    curl \
    wget \
    git \
    vim \
    net-tools \
    sudo \
    lsb-release \
    software-properties-common \
    apt-transport-https \
    ca-certificates \
    gnupg \
    && rm -rf /var/lib/apt/lists/*

# Install Docker
RUN curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add - \
    && add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    && apt-get update \
    && apt-get install -y docker-ce docker-ce-cli containerd.io

# Set up a non-root user (optional, but recommended)
ARG USERNAME=vscode
ARG USER_UID=1000
ARG USER_GID=$USER_UID

RUN groupadd --gid $USER_GID $USERNAME \
    && useradd --uid $USER_UID --gid $USER_GID -m $USERNAME \
    && echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Add the user to the docker group
RUN usermod -aG docker $USERNAME

# Switch to non-root user
USER $USERNAME

# Set the working directory
WORKDIR /workspace

# Expose port 80
EXPOSE 80
