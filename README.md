# Claude Dangerous Mode Container

A Docker container with Ubuntu 24.04, Node.js 24, Bun, Git, Claude CLI, and essential development tools for running Claude in dangerous mode.

## Features

- **Ubuntu 24.04** - Full-featured base image
- **Node.js 24** - Latest LTS
- **Bun** - Fast JavaScript runtime
- **Claude CLI** - Anthropic's official CLI
- **Git** - Version control
- **GitHub CLI** - Create PRs, manage issues, and more
- **PostgreSQL Support** - Automatic database provisioning per session with PostgreSQL client tools
- **Development Tools** - ripgrep, fd-find, jq, vim, nano, tmux, htop, and more
- **Build Tools** - gcc, make, python3, pip
- **Session Manager** - Manage multiple isolated Claude sessions with git worktree support
- **Secret Management** - Secure handling of API keys and credentials with automatic leak prevention

## Session Manager (Recommended)

The `claude-session.sh` script makes it easy to manage multiple isolated Claude sessions. Each session runs in its own container with a complete copy of your repository and git worktree support.

### Quick Start with Session Manager

```bash
# Build the image
docker build -t claude-dangerous .

# Start a new session from any git repository
cd /path/to/your/project
./claude-session.sh start

# List all sessions
./claude-session.sh list

# Attach to an existing session
./claude-session.sh attach <session-name>

# Delete a session
./claude-session.sh delete <session-name>
```

**See [README-sessions.md](README-sessions.md) for complete documentation.**

### GitHub Authentication

Setup GitHub CLI for all sessions:

```bash
./claude-session.sh github-auth
```

Inside Claude sessions, you can now use:
- `gh pr create` - Create pull requests
- `gh pr list` - List PRs
- `gh issue create` - Create issues
- All other gh CLI commands

### Database Support

Each session automatically provisions an isolated PostgreSQL database. Perfect for TypeScript projects that need database connectivity.

```bash
# Start a session (database is automatically created)
./claude-session.sh start

# Inside the session, check database status
claude-db status

# Use in your TypeScript code
# DATABASE_URL is automatically configured
```

**Database Helper Commands:**
- `claude-db status` - Check connection
- `claude-db psql` - Open PostgreSQL shell
- `claude-db import schema.sql` - Import SQL file
- `claude-db export backup.sql` - Export database
- `claude-db info` - View connection details

**Disable database if not needed:**
```bash
CLAUDE_DB_ENABLED=false ./claude-session.sh start
```

**See [README-database.md](README-database.md) for complete documentation.**

### Secret Management

The session manager provides secure secret handling:

#### Global Secrets (All Sessions)

Store API keys and credentials in:
```
~/.config/claude-container/secrets/.env.global
```

Example:
```bash
OPENAI_API_KEY=sk-...
AWS_ACCESS_KEY_ID=AKIA...
```

#### Project Secrets (Per Session)

Each session auto-creates a `.env` file:
```bash
./claude-session.sh start
# A .env file is created automatically in your project
# Add project-specific secrets there
```

#### Secret Files

Store credential files (like `service-account.json`) in:
```
~/.config/claude-container/secrets/
```

Access them in sessions at `/secrets/filename`.

#### Protection

Secret files are automatically:
- Added to `.gitignore`
- Blocked from Claude reading/editing (configurable)
- Mounted read-only in containers

## Quick Start

### 1. Build the image

```bash
docker-compose build
```

### 2. Set up Claude credentials

First, create the config directory:

```bash
mkdir -p claude-config
```

Then either:
- Copy your existing Claude config: `cp -r ~/.config/claude/* claude-config/`
- Or run the container and authenticate: `docker-compose run --rm claude-dev claude auth login`

### 3. Run the container

```bash
docker-compose run --rm claude-dev
```

Or use Docker directly:

```bash
docker build -t claude-dangerous .
docker run -it --rm \
  -v $(pwd)/claude-config:/config \
  -v $(pwd)/workspace:/workspace \
  -e CLAUDE_CONFIG_DIR=/config \
  claude-dangerous
```

## Running Claude in Dangerous Mode

Inside the container:

```bash
claude chat --dangerously-disable-sandbox
```

Or with a specific directory:

```bash
cd /workspace/your-project
claude chat --dangerously-disable-sandbox
```

## Project Structure

```
.
├── Dockerfile              # Container definition
├── docker-compose.yml      # Docker Compose configuration (for manual usage)
├── claude-session.sh       # Session manager script (recommended)
├── README.md               # This file
├── README-sessions.md      # Session manager documentation
├── claude-config/          # Claude credentials (gitignored)
└── workspace/              # Your projects (manual usage)
```

## Tips

- The `workspace` directory is mounted from your host, so changes persist
- Claude config is stored in `claude-config` and mounted to `/config` in the container
- All tools (bun, node, git, etc.) are pre-installed and ready to use
- The container runs as root, giving Claude full permissions

## Installed Tools

- curl, wget, git
- GitHub CLI (gh)
- Node.js 24, npm, Bun
- Claude CLI
- Python 3 with pip
- Build tools (gcc, make, etc.)
- Text editors (vim, nano)
- Utilities (jq, ripgrep, fd-find, tmux, htop)
