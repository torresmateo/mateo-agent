#!/usr/bin/env bash

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

DOCKER_IMAGE="${CLAUDE_IMAGE:-claude-dangerous}"
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.config/claude-container/config}"
LABEL_PREFIX="claude-session"

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
    -e CLAUDE_CONFIG_DIR=/config \
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

  # Remove container
  echo "Removing container..."
  docker rm -f "$container_name" >/dev/null
  echo "✓ Container deleted"
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
    -e CLAUDE_CONFIG_DIR=/config \
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
    echo "$exited" | xargs docker rm >/dev/null
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

OPTIONS:
  start command:
    --branch <name>      Branch name for worktree
    --no-worktree        Skip worktree creation
    --exclude <patterns> Comma-separated patterns to exclude (e.g., "node_modules,dist")

  delete command:
    --force, -f          Skip confirmation

  clone command:
    --branch <name>      Branch name for new worktree

CONFIGURATION:
  Image:       $DOCKER_IMAGE
  Config Dir:  $CONFIG_DIR

  Override with environment variables:
    CLAUDE_IMAGE         Docker image name
    CLAUDE_CONFIG_DIR    Claude credentials directory

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
    *)
      echo "Error: Unknown subcommand: $subcommand"
      echo ""
      cmd_help
      exit 1
      ;;
  esac
}

main "$@"
