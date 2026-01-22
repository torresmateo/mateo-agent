FROM ubuntu:24.04

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive \
    CLAUDE_CONFIG_DIR=/config \
    NODE_VERSION=24 \
    BUN_INSTALL=/usr/local

# Install base utilities and dependencies
RUN apt-get update && apt-get install -y \
    curl \
    wget \
    git \
    ca-certificates \
    gnupg \
    build-essential \
    python3 \
    python3-pip \
    jq \
    vim \
    nano \
    unzip \
    zip \
    htop \
    tmux \
    ripgrep \
    fd-find \
    sudo \
    postgresql-client \
    && rm -rf /var/lib/apt/lists/*

# Install GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | \
    dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg && \
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | \
    tee /etc/apt/sources.list.d/github-cli.list > /dev/null && \
    apt-get update && \
    apt-get install -y gh && \
    rm -rf /var/lib/apt/lists/*

# Install Node.js 24 LTS
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

# Install Bun
RUN curl -fsSL https://bun.sh/install | bash

# Install Claude CLI
# To force update: docker build --build-arg CLAUDE_VERSION=$(date +%s) -t claude-dangerous .
ARG CLAUDE_VERSION=latest
RUN echo "Installing Claude version cache: $CLAUDE_VERSION" && \
    npm install -g @anthropic-ai/claude-code

# Create config directories for Claude, GitHub, and secrets
RUN mkdir -p ${CLAUDE_CONFIG_DIR} /gh-config /secrets && \
    chmod 755 /gh-config /secrets

# Install database helper script
COPY claude-db-helper.sh /usr/local/bin/claude-db
RUN chmod +x /usr/local/bin/claude-db

# Create entrypoint script to setup user
RUN echo '#!/bin/bash\n\
set -e\n\
\n\
# Create user with specified UID/GID if they dont exist\n\
USER_ID=${HOST_UID:-1000}\n\
GROUP_ID=${HOST_GID:-1000}\n\
USERNAME=${HOST_USER:-claude}\n\
\n\
# Create group if it doesnt exist\n\
if ! getent group $GROUP_ID >/dev/null; then\n\
    groupadd -g $GROUP_ID $USERNAME\n\
fi\n\
\n\
# Create user if it doesnt exist\n\
if ! getent passwd $USER_ID >/dev/null; then\n\
    useradd -u $USER_ID -g $GROUP_ID -m -s /bin/bash $USERNAME\n\
    echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers\n\
fi\n\
\n\
# Fix ownership of workspace and config\n\
chown -R $USER_ID:$GROUP_ID /workspace 2>/dev/null || true\n\
\n\
# Execute command as the user\n\
if [ "$1" = "bash" ] || [ "$1" = "/bin/bash" ]; then\n\
    exec gosu $USER_ID:$GROUP_ID /bin/bash\n\
else\n\
    exec gosu $USER_ID:$GROUP_ID "$@"\n\
fi\n\
' > /entrypoint.sh && chmod +x /entrypoint.sh

# Install gosu for better user switching than su/sudo
RUN set -eux; \
    apt-get update; \
    apt-get install -y gosu; \
    rm -rf /var/lib/apt/lists/*; \
    gosu nobody true

# Set working directory
WORKDIR /workspace

ENTRYPOINT ["/entrypoint.sh"]
CMD ["/bin/bash"]
