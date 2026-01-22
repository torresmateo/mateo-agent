# Using Claude Sessions with Monorepos

The session manager injects session-specific environment variables (like `DATABASE_URL`) directly into your `.env` file at the top. This makes them immediately available to all standard dotenv tools and allows easy overrides in subdirectories.

## How It Works

When you start a session, the session manager:
1. Injects session variables at the **top** of your root `.env` file
2. Marks them with clear comments (auto-generated section)
3. Preserves any existing variables below

**Your root `.env` after session start:**
```bash
# === CLAUDE SESSION VARIABLES (auto-generated, do not edit) ===
# These are injected by claude-session at container start
# They can be overridden by .env.local files in subdirectories
DATABASE_URL=postgresql://postgres:postgres@claude-session-meg-8-db:5432/appdb
CLAUDE_SESSION_NAME=claude-session-meg-8
CLAUDE_DB_ENABLED=true
# === END CLAUDE SESSION VARIABLES ===

# Add your project-specific secrets below
# These can override the session variables above
```

**Note:** All sessions use the same credentials (`postgres:postgres`) since each session has its own isolated database container. The only difference is the hostname (`claude-session-{SESSION_NAME}-db`).

## Usage Patterns

### Pattern 1: Standard Dotenv (Simplest)

**Monorepo structure:**
```
my-monorepo/
├── .env                          # Session vars injected at top
├── .gitignore                    # Contains .env
├── apps/
│   └── server/
│       ├── .env.local            # Optional component-specific overrides
│       └── index.ts
└── packages/
    └── api/
        ├── .env.local            # Optional overrides
        └── index.ts
```

**In `apps/server/index.ts`:**
```typescript
import dotenv from 'dotenv';
import path from 'path';

// Load root .env (contains session variables)
dotenv.config({ path: path.join(__dirname, '../../.env') });

// Load local overrides if they exist
dotenv.config({ path: path.join(__dirname, '.env.local') });

console.log(process.env.DATABASE_URL); // From root .env (session variable)
console.log(process.env.PORT);         // From .env.local (override)
```

### Pattern 2: Dotenv-flow (Recommended for Monorepos)

```typescript
// apps/server/index.ts
import { config } from 'dotenv-flow';

config({
  path: path.join(__dirname, '../..'),  // Repo root
  // Automatically loads: .env, .env.local, .env.{NODE_ENV}, .env.{NODE_ENV}.local
  // Session variables from root .env are available everywhere
});
```

### Pattern 3: Turborepo

**Root `.env`:**
```bash
# === CLAUDE SESSION VARIABLES (auto-generated, do not edit) ===
DATABASE_URL=postgresql://postgres:postgres@claude-session-meg-8-db:5432/appdb
# === END CLAUDE SESSION VARIABLES ===
```

**`apps/web/.env.local`:**
```bash
# Override or add app-specific variables
NEXT_PUBLIC_API_URL=http://localhost:3001
```

**`apps/api/.env.local`:**
```bash
# API-specific config (DATABASE_URL inherited from root)
PORT=3001
```

Turborepo automatically loads root `.env` and merges with app-specific `.env.local` files.

### Pattern 4: Docker Compose

**In `docker-compose.yml` at repo root:**
```yaml
services:
  api:
    build: ./apps/api
    env_file:
      - .env              # Session variables
      - apps/api/.env.local  # Component variables
    ports:
      - "4000:4000"
```

### Pattern 5: Nx Monorepo

**Root `.env`:**
```bash
# === CLAUDE SESSION VARIABLES (auto-generated, do not edit) ===
DATABASE_URL=postgresql://postgres:postgres@claude-session-meg-8-db:5432/appdb
# === END CLAUDE SESSION VARIABLES ===
```

**`apps/api/.env.local`:**
```bash
PORT=4000
JWT_SECRET=your-secret
```

Nx automatically loads root `.env` and merges with app `.env.local` files.

## Best Practices

1. **Never commit `.env`** - It's auto-added to `.gitignore`
2. **Use `.env.local` for overrides** - Create `.env.local` in subdirectories for component-specific config
3. **Don't edit session variables section** - The `=== CLAUDE SESSION VARIABLES ===` section is auto-managed
4. **Load order matters**: Root `.env` first, then component `.env.local` for overrides

## Override Hierarchy

Most dotenv tools follow this precedence (highest to lowest):
1. **Component `.env.local`** - App/package specific overrides
2. **Root `.env`** - Session variables + project variables
3. **Environment variables** - Already set in shell

This means you can:
- Override `DATABASE_URL` in a component's `.env.local` to point to a different database
- Add component-specific variables without affecting other components
- Keep session variables available everywhere by default

## Example: Full Stack Monorepo

**Root `.env` (auto-generated + your additions):**
```bash
# === CLAUDE SESSION VARIABLES (auto-generated, do not edit) ===
DATABASE_URL=postgresql://postgres:postgres@claude-session-meg-8-db:5432/appdb
CLAUDE_SESSION_NAME=claude-session-meg-8
CLAUDE_DB_ENABLED=true
# === END CLAUDE SESSION VARIABLES ===

# Shared secrets
JWT_SECRET=your-jwt-secret
```

**`apps/api/.env.local`:**
```bash
PORT=4000
LOG_LEVEL=debug
```

**`apps/web/.env.local`:**
```bash
NEXT_PUBLIC_API_URL=http://localhost:4000
```

**`packages/database/.env.local`:**
```bash
# No overrides needed - uses DATABASE_URL from root .env
```

## Disabling Database for Specific Sessions

If you don't need a database for a particular session:

```bash
CLAUDE_DB_ENABLED=false ./claude-session.sh start my-frontend-app

# .env will contain:
# === CLAUDE SESSION VARIABLES (auto-generated, do not edit) ===
# CLAUDE_SESSION_NAME=claude-session-my-frontend-app
# CLAUDE_DB_ENABLED=false
# === END CLAUDE SESSION VARIABLES ===
# (no DATABASE_URL)
```

## Migration from `.env.claude-session`

If you were using the old `.env.claude-session` approach:

1. **Nothing to change** - New sessions automatically use the new approach
2. **Old sessions** - The `.env.claude-session` file is no longer created or used
3. **Old code** - Update any code that sourced `.env.claude-session` to just use `.env`

The new approach is simpler and works with all standard dotenv tools out of the box.
