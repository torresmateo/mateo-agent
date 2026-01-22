#!/usr/bin/env bash

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Auto-source .env.claude-session if it exists
if [ -f .env.claude-session ]; then
  set +u  # Temporarily disable unbound variable check
  source .env.claude-session
  set -u  # Re-enable unbound variable check
elif [ -f ../.env.claude-session ]; then
  set +u
  source ../.env.claude-session
  set -u
elif [ -f ../../.env.claude-session ]; then
  set +u
  source ../../.env.claude-session
  set -u
fi

# Parse database connection details from environment (only if DATABASE_URL is set)
# postgresql://user:password@host:port/database
parse_database_url() {
  if [ -n "${DATABASE_URL:-}" ]; then
    DB_USER="${DATABASE_URL#*://}"
    DB_USER="${DB_USER%%:*}"
    DB_PASSWORD="${DATABASE_URL#*://}"
    DB_PASSWORD="${DB_PASSWORD#*:}"
    DB_PASSWORD="${DB_PASSWORD%%@*}"
    DB_HOST="${DATABASE_URL#*@}"
    DB_HOST="${DB_HOST%%:*}"
    DB_PORT="${DATABASE_URL#*@}"
    DB_PORT="${DB_PORT#*:}"
    DB_PORT="${DB_PORT%%/*}"
    DB_NAME="${DATABASE_URL##*/}"
  fi
}

show_help() {
  parse_database_url
  local host_info=""
  if [ -n "${DB_HOST:-}" ]; then
    host_info="  Database host: $DB_HOST"
  fi

  cat <<EOF
${BLUE}claude-db${NC} - Database helper for Claude sessions

${GREEN}Usage:${NC}
  claude-db <command> [options]

${GREEN}Commands:${NC}
  status              Check database connection status
  info                Show database connection information
  psql                Open PostgreSQL interactive shell
  query <SQL>         Execute a SQL query
  import <file>       Import SQL file into database
  export [file]       Export database to SQL file (default: backup.sql)
  reset               Drop and recreate the database (WARNING: destroys all data)
  help                Show this help message

${GREEN}Examples:${NC}
  claude-db status
  claude-db psql
  claude-db query "SELECT * FROM users LIMIT 10"
  claude-db import schema.sql
  claude-db export backup-$(date +%Y%m%d).sql

${GREEN}Connection:${NC}
  DATABASE_URL is automatically configured for your session
$host_info
EOF
}

check_env() {
  if [ -z "${DATABASE_URL:-}" ]; then
    echo -e "${RED}Error: DATABASE_URL is not set${NC}"
    echo "Database is not enabled for this session"
    exit 1
  fi
  parse_database_url
}

cmd_status() {
  check_env
  echo -e "${BLUE}Checking database connection...${NC}"

  if PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1" >/dev/null 2>&1; then
    echo -e "${GREEN}✓ Database is connected and ready${NC}"
    return 0
  else
    echo -e "${RED}✗ Cannot connect to database${NC}"
    return 1
  fi
}

cmd_info() {
  check_env
  cat <<EOF
${BLUE}Database Information:${NC}
  Host:     $DB_HOST
  Port:     $DB_PORT
  Database: $DB_NAME
  User:     $DB_USER

  Connection String: $DATABASE_URL
EOF
}

cmd_psql() {
  check_env
  echo -e "${BLUE}Opening PostgreSQL shell...${NC}"
  echo -e "${YELLOW}Tip: Use \\q to quit, \\? for help${NC}"
  echo ""
  PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME"
}

cmd_query() {
  check_env
  local query="$1"

  if [ -z "$query" ]; then
    echo -e "${RED}Error: SQL query required${NC}"
    echo "Usage: claude-db query \"SELECT * FROM table\""
    exit 1
  fi

  PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "$query"
}

cmd_import() {
  check_env
  local file="$1"

  if [ -z "$file" ]; then
    echo -e "${RED}Error: SQL file required${NC}"
    echo "Usage: claude-db import schema.sql"
    exit 1
  fi

  if [ ! -f "$file" ]; then
    echo -e "${RED}Error: File not found: $file${NC}"
    exit 1
  fi

  echo -e "${BLUE}Importing $file...${NC}"
  PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -f "$file"
  echo -e "${GREEN}✓ Import complete${NC}"
}

cmd_export() {
  check_env
  local file="${1:-backup.sql}"

  echo -e "${BLUE}Exporting database to $file...${NC}"
  PGPASSWORD="$DB_PASSWORD" pg_dump -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" > "$file"
  echo -e "${GREEN}✓ Export complete: $file${NC}"
}

cmd_reset() {
  check_env
  echo -e "${RED}WARNING: This will DELETE ALL DATA in the database!${NC}"
  read -p "Are you sure you want to reset the database? [y/N] " -r
  echo

  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled"
    return 0
  fi

  echo -e "${BLUE}Resetting database...${NC}"

  # Drop all tables
  PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "
    DO \$\$ DECLARE
      r RECORD;
    BEGIN
      FOR r IN (SELECT tablename FROM pg_tables WHERE schemaname = 'public') LOOP
        EXECUTE 'DROP TABLE IF EXISTS ' || quote_ident(r.tablename) || ' CASCADE';
      END LOOP;
    END \$\$;
  " >/dev/null

  echo -e "${GREEN}✓ Database reset complete${NC}"
}

# Main
case "${1:-help}" in
  status)
    cmd_status
    ;;
  info)
    cmd_info
    ;;
  psql)
    cmd_psql
    ;;
  query)
    cmd_query "${2:-}"
    ;;
  import)
    cmd_import "${2:-}"
    ;;
  export)
    cmd_export "${2:-}"
    ;;
  reset)
    cmd_reset
    ;;
  help|--help|-h)
    show_help
    ;;
  *)
    echo -e "${RED}Error: Unknown command: $1${NC}"
    echo ""
    show_help
    exit 1
    ;;
esac
