# Claude Container Session Manager

Manage multiple isolated Claude Code sessions using Docker containers with git worktree support.

## Table of Contents

- [Overview](#overview)
- [Quick Start](#quick-start)
- [Installation](#installation)
- [Usage](#usage)
- [Common Workflows](#common-workflows)
- [Configuration](#configuration)
- [Troubleshooting](#troubleshooting)
- [Advanced Usage](#advanced-usage)

## Overview

The Claude Container Session Manager (`claude-session.sh`) allows you to:

- **Create isolated sessions**: Each session runs in its own Docker container with a complete copy of your repository
- **Git worktree support**: Automatically creates git worktrees for isolated branch work
- **Persistent containers**: Sessions survive after you exit Claude and can be resumed anytime
- **Shared credentials**: Authenticate once, use in all containers
- **Session management**: List, attach, delete, and clone sessions easily

### How It Works

1. **Copy, don't mount**: Creates an isolated copy of your directory in each container (no shared state)
2. **Git worktrees**: For git repos, creates worktrees so you can work on different branches simultaneously
3. **Persistent**: Containers stay around after you exit, so you can resume work later
4. **Labeled containers**: Uses Docker labels to track metadata (source directory, branch, creation time)

## Quick Start

### 1. Build the Docker image

```bash
cd /Users/mateo/PROGRAMMING/mateo-agent
docker build -t claude-dangerous .
```

### 2. Set up authentication (first time only)

```bash
# Option 1: Copy existing credentials
mkdir -p ~/.config/claude-container/config
cp -r ~/.config/claude/* ~/.config/claude-container/config/

# Option 2: Run the script, it will prompt for authentication
./claude-session.sh start
```

### 3. Start a session

```bash
cd /path/to/your/project
/Users/mateo/PROGRAMMING/mateo-agent/claude-session.sh start
```

Or add to your PATH:

```bash
# Add to ~/.zshrc or ~/.bashrc
export PATH="/Users/mateo/PROGRAMMING/mateo-agent:$PATH"

# Then use anywhere:
claude-session.sh start
```

## Installation

### Option 1: Add to PATH (Recommended)

Add to your `~/.zshrc` or `~/.bashrc`:

```bash
export PATH="/Users/mateo/PROGRAMMING/mateo-agent:$PATH"
```

Then reload your shell:

```bash
source ~/.zshrc  # or source ~/.bashrc
```

Now you can use `claude-session.sh` from anywhere.

### Option 2: Create a symlink

```bash
ln -s /Users/mateo/PROGRAMMING/mateo-agent/claude-session.sh /usr/local/bin/claude-session
```

Now use as `claude-session` (without the `.sh`).

### Option 3: Create an alias

Add to your `~/.zshrc` or `~/.bashrc`:

```bash
alias cs='/Users/mateo/PROGRAMMING/mateo-agent/claude-session.sh'
```

Now use as `cs start`, `cs list`, etc.

## Usage

### Command Reference

#### `start [name]` - Create new session

Create a new isolated session from the current directory.

```bash
# Auto-generate name
claude-session.sh start

# Custom name
claude-session.sh start my-feature

# Specify branch name for worktree
claude-session.sh start --branch feature/auth

# Skip worktree creation (just copy files)
claude-session.sh start --no-worktree

# Exclude patterns when copying
claude-session.sh start --exclude "node_modules,dist,.next"
```

**What happens:**
1. Creates a Docker container with a unique name
2. Copies your entire directory (including `.git`) into the container
3. For git repos: Creates a new worktree on a new branch
4. Starts Claude in dangerous mode in the worktree

#### `list` - Show all sessions

Display all Claude sessions with their status.

```bash
claude-session.sh list
```

Output:
```
NAME                              STATUS    SOURCE                          BRANCH               CREATED
my-feature                        running   /Users/mateo/project            feature/auth         2026-01-11 19:05:49
20260111-190549-7015fdf7          stopped   /Users/mateo/other-project      main                 2026-01-11 18:30:22
```

#### `attach <name>` - Reconnect to session

Resume an existing session.

```bash
claude-session.sh attach my-feature
```

**Notes:**
- You can use the short name (without `claude-session-` prefix)
- Container will be started if it's stopped
- Claude will resume in the same working directory

#### `delete <name>` - Remove session

Delete a container permanently.

```bash
# With confirmation
claude-session.sh delete my-feature

# Skip confirmation
claude-session.sh delete my-feature --force
```

**Warning:** This permanently deletes the container and all its data. If you want to preserve any work, make sure it's committed and pushed to a remote.

#### `clone <source> [new-name]` - Clone session

Create a new session by copying an existing container's state.

```bash
# Auto-generate name
claude-session.sh clone my-feature

# Custom name
claude-session.sh clone my-feature my-feature-v2

# Specify branch for new worktree
claude-session.sh clone my-feature --branch feature/alternative-approach
```

**Use case:** You want to try a different approach without losing your current work.

**What happens:**
1. Copies all files from source container
2. Creates a new container
3. Creates a new git worktree on a new branch

#### `cleanup` - Remove stopped containers

Interactively remove all exited containers.

```bash
claude-session.sh cleanup
```

Useful for cleaning up old sessions you no longer need.

#### `shell <name>` - Open bash shell

Open a bash shell in the container for debugging.

```bash
claude-session.sh shell my-feature
```

**Use case:** You want to inspect files, run commands, or debug issues without starting Claude.

#### `logs <name>` - View container logs

View Docker logs for a container.

```bash
claude-session.sh logs my-feature

# Follow logs in real-time
claude-session.sh logs my-feature --follow

# Last 50 lines
claude-session.sh logs my-feature --tail 50
```

## Common Workflows

### Workflow 1: Feature Development

```bash
# Start new session for a feature
cd ~/my-project
claude-session.sh start implement-auth

# Work with Claude...
# Exit when done (Ctrl+D or type 'exit')

# Resume work later
claude-session.sh attach implement-auth

# When feature is complete, delete the session
claude-session.sh delete implement-auth
```

### Workflow 2: Multiple Approaches

```bash
# Start working on a feature
claude-session.sh start refactor-api

# After some work, want to try a different approach
# Clone the session to preserve current state
claude-session.sh clone refactor-api refactor-api-alternative

# Now you have two sessions:
# 1. refactor-api (original approach)
# 2. refactor-api-alternative (new approach)

# Compare results and delete the one you don't want
claude-session.sh delete refactor-api-alternative
```

### Workflow 3: Parallel Work

```bash
cd ~/project-a
claude-session.sh start project-a-feature

cd ~/project-b
claude-session.sh start project-b-fix

# List all sessions
claude-session.sh list

# Switch between them
claude-session.sh attach project-a-feature
claude-session.sh attach project-b-fix
```

### Workflow 4: Emergency Recovery

```bash
# You accidentally ran a destructive command
# No problem! Your host files are untouched

# Just delete the container and start fresh
claude-session.sh delete my-session --force
claude-session.sh start my-session
```

## Configuration

### Environment Variables

Override defaults with environment variables:

```bash
# Use a different Docker image
export CLAUDE_IMAGE=my-custom-claude-image

# Use a different credentials directory
export CLAUDE_CONFIG_DIR=~/.config/my-claude-creds

# Then run commands normally
claude-session.sh start
```

### Credentials Location

By default, credentials are stored in:
```
~/.config/claude-container/config/
```

This is separate from your regular Claude CLI credentials (`~/.config/claude/`) to avoid conflicts.

### Container Naming

Containers are named:
- Custom: `claude-session-<your-name>`
- Auto: `claude-session-YYYYMMDD-HHMMSS-<hash>`

Where `<hash>` is derived from your source directory path to prevent collisions.

## Troubleshooting

### Error: Docker is not running

**Problem:** Docker daemon is not running.

**Solution:**
```bash
# Start Docker Desktop or Docker daemon
open -a Docker  # macOS
# or
sudo systemctl start docker  # Linux
```

### Error: claude-dangerous image not found

**Problem:** Docker image hasn't been built yet.

**Solution:**
```bash
cd /Users/mateo/PROGRAMMING/mateo-agent
docker build -t claude-dangerous .
```

### Error: Container already exists

**Problem:** You're trying to create a session with a name that already exists.

**Solutions:**
```bash
# Option 1: Use a different name
claude-session.sh start my-feature-v2

# Option 2: Delete the existing container
claude-session.sh delete my-feature

# Option 3: Attach to the existing container
claude-session.sh attach my-feature
```

### Slow copying for large repositories

**Problem:** Copying large directories (especially with `node_modules`) takes a long time.

**Solutions:**

1. Exclude patterns when starting:
```bash
claude-session.sh start --exclude "node_modules,dist,build,.next"
```

2. Clean up unnecessary files before starting:
```bash
rm -rf node_modules
claude-session.sh start
# Then reinstall inside container if needed
```

3. Use `.dockerignore` file (future enhancement)

### Git worktree errors

**Problem:** Git commands fail or worktree not created.

**Common causes:**
- Not in a git repository → Use `--no-worktree` flag
- Detached HEAD state → Checkout a branch first
- Corrupted git state → Check git status on host

**Solution:**
```bash
# Check git status on host
git status

# If not a git repo, use --no-worktree
claude-session.sh start --no-worktree

# If detached HEAD, checkout a branch
git checkout main
claude-session.sh start
```

### Permission issues with credentials

**Problem:** Claude can't read credentials.

**Solution:**
```bash
# Check permissions
ls -la ~/.config/claude-container/config/

# Fix permissions
chmod -R 755 ~/.config/claude-container/config/

# Re-authenticate if needed
rm -rf ~/.config/claude-container/config/.claude.json
claude-session.sh start  # Will prompt for auth
```

### Container won't start

**Problem:** Container exists but won't start.

**Debug steps:**
```bash
# Check container status
docker ps -a | grep claude-session

# View logs
claude-session.sh logs <name>

# Try starting manually
docker start claude-session-<name>

# If all else fails, delete and recreate
claude-session.sh delete <name> --force
claude-session.sh start <name>
```

## Advanced Usage

### Accessing containers directly

All containers are prefixed with `claude-session-`. You can use Docker commands directly:

```bash
# List containers
docker ps -a | grep claude-session

# Inspect a container
docker inspect claude-session-my-feature

# Copy files out of a container
docker cp claude-session-my-feature:/workspace/work/myfile.txt ./

# Execute arbitrary commands
docker exec claude-session-my-feature ls -la /workspace
```

### Custom Docker image

Create a custom Dockerfile with additional tools:

```dockerfile
FROM claude-dangerous

# Add your custom tools
RUN apt-get update && apt-get install -y \
    postgresql-client \
    redis-tools \
    && rm -rf /var/lib/apt/lists/*
```

Build and use:

```bash
docker build -t my-claude-image .
export CLAUDE_IMAGE=my-claude-image
claude-session.sh start
```

### Sharing sessions with team members

Export a container:

```bash
# Export
docker export claude-session-my-feature > my-feature-session.tar

# Share my-feature-session.tar with teammate

# Teammate imports:
docker import my-feature-session.tar claude-imported
docker run -it --rm \
  -v ~/.config/claude-container/config:/config:ro \
  -e CLAUDE_CONFIG_DIR=/config \
  claude-imported bash
```

**Note:** They'll need their own Claude credentials.

### Automated cleanup

Add to your crontab to automatically clean up old containers:

```bash
# Add to crontab: Daily cleanup of containers older than 7 days
0 2 * * * /Users/mateo/PROGRAMMING/mateo-agent/claude-session.sh cleanup --force 2>&1 | logger
```

### Multiple config profiles

Use different credential sets for different contexts:

```bash
# Work profile
export CLAUDE_CONFIG_DIR=~/.config/claude-work
claude-session.sh start work-project

# Personal profile
export CLAUDE_CONFIG_DIR=~/.config/claude-personal
claude-session.sh start personal-project
```

### Inspecting container metadata

View all metadata stored in labels:

```bash
docker inspect claude-session-my-feature --format '{{json .Config.Labels}}' | jq
```

Output:
```json
{
  "claude-session.source-dir": "/Users/mateo/project",
  "claude-session.created": "2026-01-11T19:05:49Z",
  "claude-session.is-git": "true",
  "claude-session.branch": "feature-auth",
  "claude-session.parent-container": ""
}
```

## Tips & Best Practices

1. **Use descriptive names**: `claude-session.sh start implement-user-auth` is better than `claude-session.sh start test`

2. **Clean up regularly**: Run `claude-session.sh cleanup` weekly to remove old containers

3. **Commit often**: Remember, containers are isolated. Commit and push changes you want to preserve

4. **Clone for experiments**: Use `clone` when you want to try something risky without losing your current state

5. **Use shell for debugging**: If Claude gets stuck, use `claude-session.sh shell <name>` to inspect manually

6. **Exclude large directories**: Use `--exclude` to skip `node_modules`, build artifacts, etc.

7. **Check the list**: Run `claude-session.sh list` before starting a new session to see what's already running

## Comparison with Other Approaches

| Feature | claude-session | Volume Mount | nezhar/claude-container |
|---------|----------------|--------------|-------------------------|
| **Isolation** | Full copy | Shared state | Shared state |
| **Git worktrees** | ✅ Yes | ❌ Complex | ❌ No |
| **Persistence** | ✅ Yes | ⚠️ Depends | ⚠️ Depends |
| **Multiple sessions** | ✅ Easy | ❌ Conflicts | ❌ Manual |
| **Session management** | ✅ Built-in | ❌ Manual | ❌ Manual |
| **Credential sharing** | ✅ Yes | ⚠️ Manual | ✅ Yes |

## License

This script is part of the claude-agent project and is provided as-is.

## Support

For issues or questions:
1. Check the [Troubleshooting](#troubleshooting) section
2. Review Docker logs: `claude-session.sh logs <name>`
3. Open an issue on GitHub (if applicable)
