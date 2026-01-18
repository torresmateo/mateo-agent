#!/usr/bin/env bash

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

DOCKER_IMAGE="${CLAUDE_IMAGE:-claude-dangerous}"
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.config/claude-container/config}"
GH_CONFIG_DIR="${CLAUDE_GH_CONFIG_DIR:-${HOME}/.config/claude-container/gh}"
SECRETS_DIR="${CLAUDE_SECRETS_DIR:-${HOME}/.config/claude-container/secrets}"
LABEL_PREFIX="claude-session"

# Database configuration
DB_ENABLED="${CLAUDE_DB_ENABLED:-true}"
DB_IMAGE="${CLAUDE_DB_IMAGE:-postgres:17-alpine}"
DB_USER="${CLAUDE_DB_USER:-postgres}"
DB_PASSWORD="${CLAUDE_DB_PASSWORD:-postgres}"
DB_NAME="${CLAUDE_DB_NAME:-appdb}"

# ============================================================================
# Helper Functions
# ============================================================================

check_docker() {
  if ! docker info >/dev/null 2>&1; then
    echo "Error: Docker is not running"
    echo "Please start Docker and try again"
    exit 1
  fi
}

check_image() {
  if ! docker images --format '{{.Repository}}' | grep -q "^${DOCKER_IMAGE}$"; then
    echo "Error: $DOCKER_IMAGE image not found"
    echo ""
    echo "Build the image first:"
    echo "  docker build -t $DOCKER_IMAGE ."
    exit 1
  fi
}

check_credentials() {
  if [ ! -d "$CONFIG_DIR" ]; then
    echo "Claude credentials not found at $CONFIG_DIR"
    echo ""
    echo "Setting up for first time..."
    mkdir -p "$CONFIG_DIR"

    # Option 1: Copy existing credentials
    if [ -d "$HOME/.config/claude" ]; then
      read -p "Copy credentials from ~/.config/claude? [Y/n] " -r
      echo
      if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        cp -r "$HOME/.config/claude/"* "$CONFIG_DIR/"
        echo "Credentials copied"
        return 0
      fi
    fi

    # Option 2: Authenticate in container
    echo "Creating temporary container for authentication..."
    docker run -it --rm \
      -v "$CONFIG_DIR:/config" \
      -e CLAUDE_CONFIG_DIR=/config \
      "$DOCKER_IMAGE" \
      claude auth login

    echo "Authentication complete"
  fi
}

check_gh_credentials() {
  if [ ! -d "$GH_CONFIG_DIR" ] || [ ! -f "$GH_CONFIG_DIR/hosts.yml" ]; then
    return 1
  fi
  return 0
}

setup_gh_credentials() {
  echo "GitHub credentials not found at $GH_CONFIG_DIR"
  echo ""
  echo "Setting up GitHub authentication..."
  mkdir -p "$GH_CONFIG_DIR"

  # Option 1: Copy existing credentials
  if [ -d "$HOME/.config/gh" ] && [ -f "$HOME/.config/gh/hosts.yml" ]; then
    read -p "Copy GitHub credentials from ~/.config/gh? [Y/n] " -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
      cp -r "$HOME/.config/gh/"* "$GH_CONFIG_DIR/"
      echo "GitHub credentials copied"
      return 0
    fi
  fi

  # Option 2: Authenticate in container
  echo "Creating temporary container for GitHub authentication..."
  docker run -it --rm \
    -v "$GH_CONFIG_DIR:/gh-config" \
    -e GH_CONFIG_DIR=/gh-config \
    "$DOCKER_IMAGE" \
    gh auth login

  if [ $? -eq 0 ]; then
    echo ""
    echo "GitHub authentication complete"

    # Verify authentication
    docker run --rm \
      -v "$GH_CONFIG_DIR:/gh-config" \
      -e GH_CONFIG_DIR=/gh-config \
      "$DOCKER_IMAGE" \
      gh auth status

    return 0
  else
    echo "Error: GitHub authentication failed"
    return 1
  fi
}

ensure_secrets_dir() {
  if [ ! -d "$SECRETS_DIR" ]; then
    mkdir -p "$SECRETS_DIR"
    chmod 700 "$SECRETS_DIR"

    # Create global env file with example
    cat > "$SECRETS_DIR/.env.global" <<'EOF'
# Global secrets shared across all sessions
# Add your API keys and credentials here
#
# Example:
# OPENAI_API_KEY=sk-...
# AWS_ACCESS_KEY_ID=AKIA...
# DATABASE_URL=postgresql://...
EOF
    chmod 600 "$SECRETS_DIR/.env.global"

    # Create README
    cat > "$SECRETS_DIR/README.md" <<'EOF'
# Secrets Directory

This directory stores sensitive credentials used across Claude sessions.

## Files

- `.env.global` - Environment variables loaded into all sessions
- Other files - API keys, service account JSONs, etc. (mounted at /secrets in containers)

## Security

- This directory is mounted READ-ONLY into containers
- Files here should NEVER be committed to git
- Use 600 permissions for sensitive files

## Usage

### Environment Variables
Add to `.env.global`:
```
OPENAI_API_KEY=sk-...
```

### Credential Files
Store files like `service-account.json` here, access in sessions at:
```
/secrets/service-account.json
```

### Project-Specific Secrets
Use `.env` in your project workspace for project-specific secrets.
EOF
  fi
}

ensure_gitignore_protection() {
  local workspace_dir="$1"
  local gitignore="$workspace_dir/.gitignore"

  # Patterns to protect
  local patterns=(
    ".env"
    ".env.local"
    ".env.*.local"
    "*.key"
    "*.pem"
    "*credentials*.json"
    "*secrets*.json"
    "*.p12"
    "*.pfx"
  )

  # Create or update .gitignore
  touch "$gitignore"

  # Add header if not present
  if ! grep -q "# Secret protection" "$gitignore" 2>/dev/null; then
    echo "" >> "$gitignore"
    echo "# Secret protection (auto-added by claude-session)" >> "$gitignore"
  fi

  # Add each pattern if not present
  for pattern in "${patterns[@]}"; do
    if ! grep -q "^${pattern}$" "$gitignore" 2>/dev/null; then
      echo "$pattern" >> "$gitignore"
    fi
  done
}

create_env_template() {
  local workspace_dir="$1"
  local env_file="$workspace_dir/.env"
  local env_example="$workspace_dir/.env.example"

  # Create .env if it doesn't exist
  if [ ! -f "$env_file" ]; then
    cat > "$env_file" <<'EOF'
# Project-specific secrets
# This file is automatically added to .gitignore
#
# Add your API keys and configuration here:
# API_KEY=your-key-here
# DATABASE_URL=your-db-url
EOF
    chmod 600 "$env_file"
  fi

  # Create .env.example if it doesn't exist
  if [ ! -f "$env_example" ]; then
    cat > "$env_example" <<'EOF'
# Project-specific secrets template
# Copy to .env and fill in your values
#
# API_KEY=
# DATABASE_URL=
EOF
  fi
}

generate_container_name() {
  local custom_name="$1"
  local source_dir="$2"

  if [ -n "$custom_name" ]; then
    echo "claude-session-$custom_name"
  else
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local hash=$(echo -n "$source_dir" | md5sum 2>/dev/null | cut -c1-8 || echo -n "$source_dir" | md5 | cut -c1-8)
    echo "claude-session-$timestamp-$hash"
  fi
}

get_database_name() {
  local container_name="$1"
  echo "${container_name}-db"
}

get_network_name() {
  local container_name="$1"
  echo "${container_name}-net"
}

start_database() {
  local container_name="$1"
  local db_container_name=$(get_database_name "$container_name")
  local network_name=$(get_network_name "$container_name")

  if [ "$DB_ENABLED" != "true" ]; then
    return 0
  fi

  echo "Setting up database..."

  # Create Docker network
  docker network create "$network_name" >/dev/null 2>&1 || true

  # Start PostgreSQL container
  docker run -d \
    --name "$db_container_name" \
    --network "$network_name" \
    --label "${LABEL_PREFIX}.type=database" \
    --label "${LABEL_PREFIX}.session=$container_name" \
    -e POSTGRES_USER="$DB_USER" \
    -e POSTGRES_PASSWORD="$DB_PASSWORD" \
    -e POSTGRES_DB="$DB_NAME" \
    "$DB_IMAGE" >/dev/null

  # Connect session container to network
  docker network connect "$network_name" "$container_name" >/dev/null 2>&1 || true

  # Wait for database to be ready
  echo "Waiting for database to be ready..."
  local max_attempts=30
  local attempt=0
  while [ $attempt -lt $max_attempts ]; do
    if docker exec "$db_container_name" pg_isready -U "$DB_USER" >/dev/null 2>&1; then
      echo "✓ Database ready"
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 1
  done

  echo "Warning: Database did not become ready in time"
  return 1
}

stop_database() {
  local container_name="$1"
  local db_container_name=$(get_database_name "$container_name")
  local network_name=$(get_network_name "$container_name")

  # Stop and remove database container
  if docker ps -a --format '{{.Names}}' | grep -q "^${db_container_name}$"; then
    docker rm -f "$db_container_name" >/dev/null 2>&1 || true
  fi

  # Remove network
  docker network rm "$network_name" >/dev/null 2>&1 || true
}

get_container_name() {
  local input_name="$1"

  if [[ "$input_name" == claude-session-* ]]; then
    echo "$input_name"
  else
    echo "claude-session-$input_name"
  fi
}

# ============================================================================
# Subcommand Implementations
# ============================================================================

cmd_start() {
  local custom_name=""
  local branch_name=""
  local no_worktree=false
  local exclude_patterns=()

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case $1 in
      --branch)
        branch_name="$2"
        shift 2
        ;;
      --no-worktree)
        no_worktree=true
        shift
        ;;
      --exclude)
        IFS=',' read -ra patterns <<< "$2"
        exclude_patterns+=("${patterns[@]}")
        shift 2
        ;;
      *)
        custom_name="$1"
        shift
        ;;
    esac
  done

  local source_dir="$(pwd)"
  local container_name
  local is_git=false
  local work_dir="/workspace/main"

  # Validate source directory
  if [ ! -d "$source_dir" ]; then
    echo "Error: Not in a valid directory"
    exit 1
  fi

  # Check if git repository
  if git -C "$source_dir" rev-parse --git-dir >/dev/null 2>&1; then
    is_git=true
    if [ -z "$branch_name" ]; then
      branch_name="claude-session-$(date +%s)"
    fi
  fi

  # Generate container name
  container_name=$(generate_container_name "$custom_name" "$source_dir")

  # Check for name conflicts
  if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
    echo "Error: Container $container_name already exists"
    echo ""
    echo "Options:"
    echo "  1. Choose a different name: claude-session start my-custom-name"
    echo "  2. Delete existing: claude-session delete ${container_name#claude-session-}"
    echo "  3. Attach to existing: claude-session attach ${container_name#claude-session-}"
    exit 1
  fi

  echo "Creating session: $container_name"
  echo "Source: $source_dir"

  # Get current user info
  local host_uid=$(id -u)
  local host_gid=$(id -g)
  local host_user=$(id -un)

  # Ensure secrets directory exists
  ensure_secrets_dir

  # Prepare env-file argument if global secrets exist
  local env_file_arg=""
  if [ -f "$SECRETS_DIR/.env.global" ]; then
    env_file_arg="--env-file $SECRETS_DIR/.env.global"
  fi

  # Create container with labels
  docker create \
    --name "$container_name" \
    --label "${LABEL_PREFIX}.source-dir=$source_dir" \
    --label "${LABEL_PREFIX}.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --label "${LABEL_PREFIX}.is-git=$is_git" \
    --label "${LABEL_PREFIX}.branch=$branch_name" \
    --label "${LABEL_PREFIX}.host-uid=$host_uid" \
    --label "${LABEL_PREFIX}.host-gid=$host_gid" \
    -v "$CONFIG_DIR:/config" \
    -v "$GH_CONFIG_DIR:/gh-config" \
    -v "$SECRETS_DIR:/secrets:ro" \
    $env_file_arg \
    -e CLAUDE_CONFIG_DIR=/config \
    -e GH_CONFIG_DIR=/gh-config \
    -e HOST_UID=$host_uid \
    -e HOST_GID=$host_gid \
    -e HOST_USER=$host_user \
    -it \
    "$DOCKER_IMAGE" \
    >/dev/null

  # Copy repository
  echo "Copying repository to container..."
  if docker cp "$source_dir/." "$container_name:/workspace/main" >/dev/null; then
    echo "Repository copied successfully"
  else
    echo "Error: Failed to copy repository"
    docker rm "$container_name" >/dev/null
    exit 1
  fi

  # Start container
  docker start "$container_name" >/dev/null

  # Start database if enabled
  if [ "$DB_ENABLED" = "true" ]; then
    start_database "$container_name"
  fi

  # Create worktree (if git repo and not disabled)
  if [ "$is_git" = true ] && [ "$no_worktree" = false ]; then
    echo "Creating git worktree on branch: $branch_name"
    docker exec --user "$host_uid:$host_gid" "$container_name" bash -c "
      cd /workspace/main
      git config --global user.email 'claude@container.local' 2>/dev/null || true
      git config --global user.name 'Claude Session' 2>/dev/null || true
      git worktree add /workspace/work $branch_name 2>/dev/null || git worktree add /workspace/work -b $branch_name
    " >/dev/null 2>&1
    work_dir="/workspace/work"
    echo "Worktree created at: $work_dir"
  fi

  # Setup secret protection and .env template
  local db_container_name=$(get_database_name "$container_name")
  docker exec "$container_name" bash -c "
    work_dir=\"work\"
    if [ ! -d /workspace/work/.git ]; then
      work_dir=\"main\"
    fi
    cd /workspace/\$work_dir

    # Create .env if not exists
    if [ ! -f .env ]; then
      cat > .env <<'EOF'
# Project-specific secrets
# This file is automatically added to .gitignore
EOF
      chmod 600 .env
    fi

    # Add DATABASE_URL to .env if database is enabled
    if [ '$DB_ENABLED' = 'true' ] && ! grep -q 'DATABASE_URL=' .env; then
      echo '' >> .env
      echo '# Database connection (auto-configured by claude-session)' >> .env
      echo 'DATABASE_URL=postgresql://$DB_USER:$DB_PASSWORD@$db_container_name:5432/$DB_NAME' >> .env
    fi

    # Create .env.example if not exists
    if [ ! -f .env.example ]; then
      cat > .env.example <<'EOF'
# Project-specific secrets template
# Copy to .env and fill in your values
#
# DATABASE_URL=postgresql://user:password@host:5432/database
EOF
    fi

    # Update .gitignore
    if [ -f .git/config ] || [ -f ../.git/config ]; then
      touch .gitignore
      if ! grep -q '# Secret protection' .gitignore; then
        echo '' >> .gitignore
        echo '# Secret protection (auto-added by claude-session)' >> .gitignore
      fi

      for pattern in .env .env.local '.env.*.local' '*.key' '*.pem' '*credentials*.json' '*secrets*.json' '*.p12' '*.pfx'; do
        if ! grep -q \"^\${pattern}\$\" .gitignore; then
          echo \"\$pattern\" >> .gitignore
        fi
      done
    fi
  " 2>/dev/null || true

  # Clean up excluded patterns
  if [ ${#exclude_patterns[@]} -gt 0 ]; then
    echo "Cleaning up excluded patterns..."
    for pattern in "${exclude_patterns[@]}"; do
      docker exec --user "$host_uid:$host_gid" "$container_name" bash -c "cd /workspace/main && rm -rf $pattern" 2>/dev/null || true
    done
  fi

  echo ""
  echo "✓ Session created successfully!"
  echo ""
  echo "Working directory: $work_dir"
  echo "To attach later: claude-session attach ${container_name#claude-session-}"
  echo ""
  echo "Starting Claude..."
  echo ""

  # Start Claude
  docker exec -it --user "$host_uid:$host_gid" "$container_name" bash -c "
    cd $work_dir
    exec claude --dangerously-skip-permissions
  "
}

cmd_list() {
  local containers=$(docker ps -a \
    --filter "label=${LABEL_PREFIX}.source-dir" \
    --format "{{.Names}}|{{.Status}}|{{.Label \"${LABEL_PREFIX}.source-dir\"}}|{{.Label \"${LABEL_PREFIX}.branch\"}}|{{.CreatedAt}}")

  if [ -z "$containers" ]; then
    echo "No sessions found"
    echo ""
    echo "Create a session with: claude-session start"
    return 0
  fi

  printf "%-35s %-20s %-40s %-25s %s\n" "NAME" "STATUS" "SOURCE" "BRANCH" "CREATED"
  echo "$(printf '%.0s-' {1..150})"

  echo "$containers" | while IFS='|' read -r name status source branch created; do
    # Color code by status
    if [[ "$status" == Up* ]]; then
      color="\033[0;32m"  # Green
      status="running"
    else
      color="\033[0;90m"  # Gray
      status="stopped"
    fi

    # Truncate long paths
    if [ ${#source} -gt 40 ]; then
      source="...${source: -37}"
    fi

    # Remove claude-session- prefix for display
    display_name="${name#claude-session-}"

    printf "${color}%-35s %-20s %-40s %-25s %s\033[0m\n" \
      "$display_name" "$status" "$source" "$branch" "${created:0:19}"
  done
}

cmd_attach() {
  local input_name="$1"

  if [ -z "$input_name" ]; then
    echo "Error: Container name required"
    echo ""
    echo "Usage: claude-session attach <name>"
    echo ""
    echo "Available sessions:"
    cmd_list
    exit 1
  fi

  local container_name=$(get_container_name "$input_name")

  # Check if container exists
  if ! docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
    echo "Error: Container $container_name not found"
    echo ""
    echo "Available sessions:"
    cmd_list
    exit 1
  fi

  # Start if not running
  if ! docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
    echo "Starting container..."
    docker start "$container_name" >/dev/null

    # Restart database if enabled
    if [ "$DB_ENABLED" = "true" ]; then
      local db_container_name=$(get_database_name "$container_name")
      if docker ps -a --format '{{.Names}}' | grep -q "^${db_container_name}$"; then
        if ! docker ps --format '{{.Names}}' | grep -q "^${db_container_name}$"; then
          echo "Restarting database..."
          docker start "$db_container_name" >/dev/null
        fi
      else
        # Database doesn't exist, create it
        start_database "$container_name"
      fi
    fi
  fi

  # Get user info from container labels
  local host_uid=$(docker inspect "$container_name" --format '{{index .Config.Labels "'${LABEL_PREFIX}'.host-uid"}}')
  local host_gid=$(docker inspect "$container_name" --format '{{index .Config.Labels "'${LABEL_PREFIX}'.host-gid"}}')

  # Determine working directory
  local is_git=$(docker inspect "$container_name" --format '{{index .Config.Labels "'${LABEL_PREFIX}'.is-git"}}')
  local work_dir="/workspace/main"

  if [ "$is_git" = "true" ]; then
    # Check if worktree exists
    if docker exec --user "$host_uid:$host_gid" "$container_name" test -d /workspace/work 2>/dev/null; then
      work_dir="/workspace/work"
    fi
  fi

  echo "Attaching to: ${container_name#claude-session-}"
  echo "Working directory: $work_dir"
  echo ""

  # Attach to Claude
  docker exec -it --user "$host_uid:$host_gid" "$container_name" bash -c "
    cd $work_dir
    exec claude --dangerously-skip-permissions
  "
}

cmd_delete() {
  local input_name=""
  local force=false

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case $1 in
      -f|--force)
        force=true
        shift
        ;;
      *)
        input_name="$1"
        shift
        ;;
    esac
  done

  if [ -z "$input_name" ]; then
    echo "Error: Container name required"
    echo ""
    echo "Usage: claude-session delete <name> [--force]"
    exit 1
  fi

  local container_name=$(get_container_name "$input_name")

  # Check if exists
  if ! docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
    echo "Error: Container $container_name not found"
    echo ""
    echo "Available sessions:"
    cmd_list
    exit 1
  fi

  # Show container info
  echo "Container: ${container_name#claude-session-}"
  docker inspect "$container_name" --format 'Source: {{index .Config.Labels "'${LABEL_PREFIX}'.source-dir"}}'
  docker inspect "$container_name" --format 'Created: {{index .Config.Labels "'${LABEL_PREFIX}'.created"}}'
  echo ""

  # Confirm deletion
  if [ "$force" = false ]; then
    read -p "Delete this container? [y/N] " -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      echo "Cancelled"
      exit 0
    fi
  fi

  # Remove database and network if they exist
  echo "Removing container and database..."
  stop_database "$container_name"
  docker rm -f "$container_name" >/dev/null
  echo "✓ Container and database deleted"
}

cmd_clone() {
  local source_container="$1"
  local new_name="${2:-}"
  local new_branch=""

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case $1 in
      --branch)
        new_branch="$2"
        shift 2
        ;;
      *)
        if [ -z "$source_container" ]; then
          source_container="$1"
        elif [ -z "$new_name" ]; then
          new_name="$1"
        fi
        shift
        ;;
    esac
  done

  if [ -z "$source_container" ]; then
    echo "Error: Source container name required"
    echo ""
    echo "Usage: claude-session clone <source> [new-name] [--branch <branch>]"
    exit 1
  fi

  # Add prefix if needed
  source_container=$(get_container_name "$source_container")

  # Check source exists
  if ! docker ps -a --format '{{.Names}}' | grep -q "^${source_container}$"; then
    echo "Error: Source container not found"
    echo ""
    echo "Available sessions:"
    cmd_list
    exit 1
  fi

  # Get source metadata
  local source_dir=$(docker inspect "$source_container" --format '{{index .Config.Labels "'${LABEL_PREFIX}'.source-dir"}}')
  local is_git=$(docker inspect "$source_container" --format '{{index .Config.Labels "'${LABEL_PREFIX}'.is-git"}}')

  # Generate new container name
  if [ -n "$new_name" ]; then
    new_container="claude-session-$new_name"
  else
    local timestamp=$(date +%Y%m%d-%H%M%S)
    new_container="claude-session-clone-$timestamp"
  fi

  # Check for conflicts
  if docker ps -a --format '{{.Names}}' | grep -q "^${new_container}$"; then
    echo "Error: Container $new_container already exists"
    exit 1
  fi

  # Generate branch name
  if [ -z "$new_branch" ]; then
    new_branch="claude-clone-$(date +%s)"
  fi

  echo "Cloning ${source_container#claude-session-} → ${new_container#claude-session-}"

  # Get current user info
  local host_uid=$(id -u)
  local host_gid=$(id -g)
  local host_user=$(id -un)

  # Ensure secrets directory exists
  ensure_secrets_dir

  # Prepare env-file argument if global secrets exist
  local env_file_arg=""
  if [ -f "$SECRETS_DIR/.env.global" ]; then
    env_file_arg="--env-file $SECRETS_DIR/.env.global"
  fi

  # Create new container
  docker create \
    --name "$new_container" \
    --label "${LABEL_PREFIX}.source-dir=$source_dir" \
    --label "${LABEL_PREFIX}.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --label "${LABEL_PREFIX}.is-git=$is_git" \
    --label "${LABEL_PREFIX}.branch=$new_branch" \
    --label "${LABEL_PREFIX}.parent-container=$source_container" \
    --label "${LABEL_PREFIX}.host-uid=$host_uid" \
    --label "${LABEL_PREFIX}.host-gid=$host_gid" \
    -v "$CONFIG_DIR:/config" \
    -v "$GH_CONFIG_DIR:/gh-config" \
    -v "$SECRETS_DIR:/secrets:ro" \
    $env_file_arg \
    -e CLAUDE_CONFIG_DIR=/config \
    -e GH_CONFIG_DIR=/gh-config \
    -e HOST_UID=$host_uid \
    -e HOST_GID=$host_gid \
    -e HOST_USER=$host_user \
    -it \
    "$DOCKER_IMAGE" \
    >/dev/null

  # Copy workspace from source container
  echo "Copying workspace from source container..."
  local temp_dir=$(mktemp -d)
  trap "rm -rf $temp_dir" EXIT

  docker cp "$source_container:/workspace/." "$temp_dir/" >/dev/null
  docker cp "$temp_dir/." "$new_container:/workspace/" >/dev/null

  echo "Workspace copied successfully"

  # Start new container
  docker start "$new_container" >/dev/null

  # Create new worktree
  if [ "$is_git" = "true" ]; then
    echo "Creating new worktree on branch: $new_branch"
    docker exec --user "$host_uid:$host_gid" "$new_container" bash -c "
      cd /workspace/main
      git worktree add /workspace/work-clone $new_branch 2>/dev/null || git worktree add /workspace/work-clone -b $new_branch
    " >/dev/null 2>&1
    echo "Worktree created at: /workspace/work-clone"
  fi

  echo ""
  echo "✓ Clone created successfully!"
  echo ""
  echo "New session: ${new_container#claude-session-}"
  echo "To attach: claude-session attach ${new_container#claude-session-}"
}

cmd_cleanup() {
  local exited=$(docker ps -a \
    --filter "label=${LABEL_PREFIX}.source-dir" \
    --filter "status=exited" \
    --format "{{.Names}}")

  if [ -z "$exited" ]; then
    echo "No exited containers to clean up"
    return 0
  fi

  echo "Exited containers:"
  docker ps -a \
    --filter "label=${LABEL_PREFIX}.source-dir" \
    --filter "status=exited" \
    --format "  - {{.Names}}\t({{.Label \"${LABEL_PREFIX}.created\"}})"
  echo ""

  read -p "Delete all exited containers? [y/N] " -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    # Clean up each container and its database
    while IFS= read -r container; do
      stop_database "$container"
      docker rm "$container" >/dev/null 2>&1 || true
    done <<< "$exited"
    echo "✓ Cleanup complete"
  else
    echo "Cancelled"
  fi
}

cmd_shell() {
  local input_name="$1"

  if [ -z "$input_name" ]; then
    echo "Error: Container name required"
    exit 1
  fi

  local container_name=$(get_container_name "$input_name")

  # Check if exists
  if ! docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
    echo "Error: Container not found"
    exit 1
  fi

  # Start if not running
  if ! docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
    echo "Starting container..."
    docker start "$container_name" >/dev/null
  fi

  # Get user info from container labels
  local host_uid=$(docker inspect "$container_name" --format '{{index .Config.Labels "'${LABEL_PREFIX}'.host-uid"}}')
  local host_gid=$(docker inspect "$container_name" --format '{{index .Config.Labels "'${LABEL_PREFIX}'.host-gid"}}')

  # Determine working directory
  local is_git=$(docker inspect "$container_name" --format '{{index .Config.Labels "'${LABEL_PREFIX}'.is-git"}}')
  local work_dir="/workspace/main"

  if [ "$is_git" = "true" ]; then
    if docker exec --user "$host_uid:$host_gid" "$container_name" test -d /workspace/work 2>/dev/null; then
      work_dir="/workspace/work"
    fi
  fi

  docker exec -it --user "$host_uid:$host_gid" "$container_name" bash -c "cd $work_dir && exec bash"
}

cmd_logs() {
  local input_name="$1"
  shift || true

  if [ -z "$input_name" ]; then
    echo "Error: Container name required"
    exit 1
  fi

  local container_name=$(get_container_name "$input_name")

  docker logs "$container_name" "$@"
}

cmd_github_auth() {
  local force_reauth=false

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case $1 in
      --reauth)
        force_reauth=true
        shift
        ;;
      *)
        echo "Error: Unknown option: $1"
        echo ""
        echo "Usage: claude-session github-auth [--reauth]"
        exit 1
        ;;
    esac
  done

  # Check current status
  if check_gh_credentials && [ "$force_reauth" = false ]; then
    echo "GitHub credentials already configured"
    echo ""
    echo "Verifying authentication..."
    docker run --rm \
      -v "$GH_CONFIG_DIR:/gh-config" \
      -e GH_CONFIG_DIR=/gh-config \
      "$DOCKER_IMAGE" \
      gh auth status

    echo ""
    echo "To re-authenticate, run: claude-session github-auth --reauth"
    return 0
  fi

  # Force re-authentication if requested
  if [ "$force_reauth" = true ]; then
    echo "Re-authenticating with GitHub..."
    echo ""
  fi

  # Setup or re-setup credentials
  if setup_gh_credentials; then
    echo ""
    echo "✓ GitHub authentication configured successfully!"
    echo ""
    echo "GitHub CLI (gh) is now available in all Claude sessions."

    # Check if permissions need updating
    local settings_file=".claude/settings.local.json"
    if [ -f "$settings_file" ]; then
      if ! grep -q "Bash(gh:" "$settings_file" 2>/dev/null; then
        echo ""
        echo "NOTE: Add GitHub CLI permissions to $settings_file:"
        echo ""
        cat <<'EOF'
  "Bash(gh:*)",
  "Bash(gh auth:*)",
  "Bash(gh pr:*)",
  "Bash(gh issue:*)"
EOF
      fi
    fi
  else
    echo "GitHub authentication setup failed"
    exit 1
  fi
}

cmd_upgrade() {
  local input_name="$1"

  if [ -z "$input_name" ]; then
    echo "Error: Container name required"
    echo ""
    echo "Usage: claude-session upgrade <name>"
    echo ""
    echo "Available containers:"
    cmd_list
    exit 1
  fi

  local container_name=$(get_container_name "$input_name")
  local backup_dir=$(mktemp -d)

  # Check if container exists
  if ! docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
    echo "Error: Container not found: $input_name"
    echo ""
    echo "Available containers:"
    cmd_list
    exit 1
  fi

  echo "╔══════════════════════════════════════════════════════════════════╗"
  echo "║  Upgrading Container: $input_name"
  echo "╚══════════════════════════════════════════════════════════════════╝"
  echo ""

  # Get container metadata
  local source_dir=$(docker inspect "$container_name" --format '{{index .Config.Labels "'${LABEL_PREFIX}'.source-dir"}}')
  local branch=$(docker inspect "$container_name" --format '{{index .Config.Labels "'${LABEL_PREFIX}'.branch"}}')
  local is_git=$(docker inspect "$container_name" --format '{{index .Config.Labels "'${LABEL_PREFIX}'.is-git"}}')

  echo "Container info:"
  echo "  • Name: $input_name"
  echo "  • Source: $source_dir"
  echo "  • Branch: $branch"
  echo "  • Is Git: $is_git"
  echo ""

  # Step 1: Backup the workspace
  echo "Step 1: Backing up workspace..."
  if docker cp "$container_name:/workspace/." "$backup_dir/" >/dev/null 2>&1; then
    echo "  ✓ Workspace backed up"
  else
    echo "  ✗ Failed to backup workspace"
    rm -rf "$backup_dir"
    exit 1
  fi

  # Step 2: Stop and remove old container
  echo ""
  echo "Step 2: Removing old container..."
  docker stop "$container_name" >/dev/null 2>&1 || true
  docker rm "$container_name" >/dev/null 2>&1
  echo "  ✓ Old container removed"

  # Step 3: Create new container with new image
  echo ""
  echo "Step 3: Creating new container with updated image..."

  # Determine working directory from backup
  local work_dir="work"
  if [ ! -d "$backup_dir/work/.git" ]; then
    work_dir="main"
  fi

  cd "$source_dir"

  # Create new session without starting Claude
  if [ "$is_git" = "true" ] && [ -n "$branch" ]; then
    # Start with the branch name
    cmd_start "$input_name" --branch "$branch" > /dev/null 2>&1 &
    local session_pid=$!

    # Wait for container to be created and started
    sleep 5

    # Kill Claude that auto-started
    docker exec "$container_name" pkill -9 claude 2>/dev/null || true
    kill $session_pid 2>/dev/null || true
    wait $session_pid 2>/dev/null || true
  else
    # Non-git or no worktree
    cmd_start "$input_name" --no-worktree > /dev/null 2>&1 &
    local session_pid=$!

    sleep 5
    docker exec "$container_name" pkill -9 claude 2>/dev/null || true
    kill $session_pid 2>/dev/null || true
    wait $session_pid 2>/dev/null || true
  fi

  echo "  ✓ New container created with updated image"

  # Step 4: Restore workspace
  echo ""
  echo "Step 4: Restoring your changes..."
  if docker cp "$backup_dir/." "$container_name:/workspace/" >/dev/null 2>&1; then
    echo "  ✓ Workspace restored"
  else
    echo "  ✗ Failed to restore workspace"
    rm -rf "$backup_dir"
    exit 1
  fi

  # Fix git ownership if it's a git repo
  if [ "$is_git" = "true" ]; then
    docker exec "$container_name" bash -c 'git config --global --add safe.directory /workspace/main 2>/dev/null || true' >/dev/null 2>&1
    if [ -d "$backup_dir/work/.git" ]; then
      docker exec "$container_name" bash -c 'git config --global --add safe.directory /workspace/work 2>/dev/null || true' >/dev/null 2>&1
    fi
  fi

  # Step 5: Verify
  echo ""
  echo "Step 5: Verifying upgrade..."
  local gh_version=$(docker exec "$container_name" gh --version 2>/dev/null | head -1 || echo 'Not available')
  local gh_config_count=$(docker exec "$container_name" ls /gh-config 2>/dev/null | wc -l | tr -d ' ')
  local secrets_count=$(docker exec "$container_name" ls /secrets 2>/dev/null | wc -l | tr -d ' ')

  echo "  • gh CLI: $gh_version"
  echo "  • GitHub config: $gh_config_count files mounted"
  echo "  • Secrets dir: $secrets_count files mounted"
  echo "  • Working dir: /workspace/$work_dir"

  # Cleanup
  echo ""
  echo "Step 6: Cleaning up backup..."
  rm -rf "$backup_dir"
  echo "  ✓ Backup removed"

  echo ""
  echo "╔══════════════════════════════════════════════════════════════════╗"
  echo "║  ✅ Container upgraded successfully!                              ║"
  echo "╚══════════════════════════════════════════════════════════════════╝"
  echo ""
  echo "Your changes have been preserved. To attach to the upgraded container:"
  echo "  claude-session attach $input_name"
}

cmd_help() {
  cat <<'EOF'
Claude Container Session Manager

Manage isolated Claude sessions in Docker containers with git worktree support.

USAGE:
  claude-session <subcommand> [options]

SUBCOMMANDS:
  start [name]         Create new session from current directory
  list                 Show all sessions
  attach <name>        Reconnect to existing session
  delete <name>        Remove session
  clone <src> [name]   Clone existing session with new worktree
  cleanup              Remove all exited containers
  shell <name>         Open bash shell in container
  logs <name>          View container logs
  upgrade <name>       Upgrade container to latest image (preserves changes)
  github-auth          Configure GitHub authentication for all sessions
  help                 Show this help

EXAMPLES:
  # Start new session in current directory
  claude-session start

  # Start with custom name
  claude-session start my-feature

  # Start with specific branch name
  claude-session start --branch feature/new-auth

  # Start without creating worktree
  claude-session start --no-worktree

  # List all sessions
  claude-session list

  # Attach to session
  claude-session attach my-feature

  # Delete session
  claude-session delete my-feature

  # Force delete without confirmation
  claude-session delete my-feature --force

  # Clone session with new worktree
  claude-session clone my-feature my-feature-v2

  # Open shell for debugging
  claude-session shell my-feature

  # Clean up stopped containers
  claude-session cleanup

  # Upgrade container to latest image
  claude-session upgrade my-feature

  # Setup GitHub authentication
  claude-session github-auth

  # Re-authenticate with GitHub
  claude-session github-auth --reauth

SECRETS MANAGEMENT:
  Global secrets are stored in:
    ~/.config/claude-container/secrets/

  Files:
    .env.global         Global environment variables for all sessions
    *.key, *.json       Credential files (mounted at /secrets in containers)

  Project secrets:
    .env                Auto-created in each project (added to .gitignore)
    .env.example        Template (safe to commit)

  Secret files are automatically protected from git commits.

OPTIONS:
  start command:
    --branch <name>      Branch name for worktree
    --no-worktree        Skip worktree creation
    --exclude <patterns> Comma-separated patterns to exclude (e.g., "node_modules,dist")

  delete command:
    --force, -f          Skip confirmation

  clone command:
    --branch <name>      Branch name for new worktree

  github-auth command:
    --reauth             Force re-authentication

CONFIGURATION:
  Image:          $DOCKER_IMAGE
  Config Dir:     $CONFIG_DIR
  GitHub Config:  $GH_CONFIG_DIR
  Secrets Dir:    $SECRETS_DIR

  Override with environment variables:
    CLAUDE_IMAGE            Docker image name
    CLAUDE_CONFIG_DIR       Claude credentials directory
    CLAUDE_GH_CONFIG_DIR    GitHub credentials directory
    CLAUDE_SECRETS_DIR      Secrets storage directory

For more information, see README-sessions.md
EOF
}

# ============================================================================
# Main Entry Point
# ============================================================================

main() {
  local subcommand="${1:-help}"

  # Help can run without checks
  if [ "$subcommand" = "help" ] || [ "$subcommand" = "--help" ] || [ "$subcommand" = "-h" ]; then
    cmd_help
    exit 0
  fi

  shift || true

  # Run prerequisite checks
  check_docker
  check_image

  # Check credentials for commands that need them
  if [ "$subcommand" = "start" ] || [ "$subcommand" = "attach" ] || [ "$subcommand" = "clone" ]; then
    check_credentials
  fi

  case "$subcommand" in
    start)   cmd_start "$@" ;;
    list|ls) cmd_list "$@" ;;
    attach)  cmd_attach "$@" ;;
    delete|rm) cmd_delete "$@" ;;
    clone)   cmd_clone "$@" ;;
    cleanup) cmd_cleanup "$@" ;;
    shell)   cmd_shell "$@" ;;
    logs)    cmd_logs "$@" ;;
    upgrade) cmd_upgrade "$@" ;;
    github-auth) cmd_github_auth "$@" ;;
    *)
      echo "Error: Unknown subcommand: $subcommand"
      echo ""
      cmd_help
      exit 1
      ;;
  esac
}

main "$@"
