# Database Support for Claude Sessions

Each Claude session can automatically provision an isolated PostgreSQL database that your TypeScript projects can connect to.

## Features

- **Isolated PostgreSQL Instance**: Each session gets its own PostgreSQL container
- **Automatic Connection Configuration**: `DATABASE_URL` is automatically set in your environment
- **Lifecycle Management**: Database is created with the session and cleaned up when deleted
- **Helper Commands**: Use `claude-db` for common database operations
- **Network Isolation**: Containers communicate over a dedicated Docker network

## Quick Start

### 1. Enable Database (Default)

Databases are enabled by default. To start a session with a database:

```bash
claude-session start
```

The database will be automatically created and configured.

### 2. Check Database Connection

Inside your Claude session:

```bash
claude-db status
```

### 3. Use in Your TypeScript Project

The `DATABASE_URL` environment variable is automatically configured:

```typescript
// Example with node-postgres (pg)
import { Pool } from 'pg';

const pool = new Pool({
  connectionString: process.env.DATABASE_URL
});

const result = await pool.query('SELECT NOW()');
console.log(result.rows[0]);
```

## Database Helper Commands

The `claude-db` command provides convenient database operations:

### Check Connection Status
```bash
claude-db status
```

### View Connection Information
```bash
claude-db info
```

### Open PostgreSQL Shell
```bash
claude-db psql
```

### Execute SQL Query
```bash
claude-db query "SELECT * FROM users LIMIT 10"
```

### Import SQL File
```bash
claude-db import schema.sql
```

### Export Database
```bash
claude-db export backup-$(date +%Y%m%d).sql
```

### Reset Database (WARNING: Destroys all data)
```bash
claude-db reset
```

## Configuration

### Environment Variables

You can customize database settings via environment variables:

```bash
# Disable database (if you don't need it)
export CLAUDE_DB_ENABLED=false

# Customize database image (default: postgres:17-alpine)
export CLAUDE_DB_IMAGE=postgres:16-alpine
```

**Note:** Database credentials are fixed at `postgres:postgres` with database name `appdb`. Since each session has its own isolated container, there's no collision risk and no need to customize credentials per session.

Then start your session:

```bash
claude-session start
```

### Disable Database for a Single Session

```bash
CLAUDE_DB_ENABLED=false claude-session start
```

## Common Use Cases

### Using with Prisma

```typescript
// prisma/schema.prisma
datasource db {
  provider = "postgresql"
  url      = env("DATABASE_URL")
}

// Run migrations
await $`npx prisma migrate dev`
```

### Using with TypeORM

```typescript
import { DataSource } from 'typeorm';

const AppDataSource = new DataSource({
  type: 'postgres',
  url: process.env.DATABASE_URL,
  entities: ['src/entities/**/*.ts'],
  synchronize: true,
});

await AppDataSource.initialize();
```

### Using with Drizzle ORM

```typescript
import { drizzle } from 'drizzle-orm/node-postgres';
import { Pool } from 'pg';

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
});

const db = drizzle(pool);
```

### Running SQL Scripts

```bash
# Run schema initialization
claude-db import schema.sql

# Run seed data
claude-db import seeds/sample-data.sql
```

## Connection Details

The `DATABASE_URL` is automatically configured as:

```
postgresql://postgres:postgres@<session-name>-db:5432/appdb
```

Individual components are also available:
- **Host**: `<session-name>-db` (Docker network hostname)
- **Port**: `5432`
- **User**: `postgres` (configurable)
- **Password**: `postgres` (configurable)
- **Database**: `appdb` (configurable)

## Lifecycle Management

### Session Start
- Docker network is created
- PostgreSQL container is started
- Health check waits for database to be ready
- Session container is connected to the network
- `DATABASE_URL` is injected into the environment

### Session Attach
- If database container is stopped, it's automatically restarted
- Connection remains persistent across attaches

### Session Delete
- Database container is removed
- Docker network is cleaned up
- All data is destroyed (databases are ephemeral)

## Persistence and Backups

**Important**: Databases are ephemeral and tied to the session lifecycle. When you delete a session, all database data is lost.

### To Preserve Data

1. **Export before deletion**:
   ```bash
   claude-db export backup.sql
   ```

2. **Import into new session**:
   ```bash
   claude-db import backup.sql
   ```

3. **Use volumes** (advanced):
   Modify `claude-session.sh` to add volume mounts for PostgreSQL data directory

## Troubleshooting

### Database won't start
```bash
# Check if database container exists
docker ps -a | grep db

# View database logs
docker logs <session-name>-db
```

### Connection refused
```bash
# Verify database is running
claude-db status

# Check network connectivity
docker exec <session-name> ping <session-name>-db
```

### Wrong credentials
Make sure you're using the configured credentials:
```bash
claude-db info
```

## Advanced Usage

### Multiple Databases

Each session gets one database by default. To use multiple databases in a project:

```bash
# Connect to default database
claude-db psql

# Create additional databases
CREATE DATABASE myapp_test;
CREATE DATABASE myapp_dev;
```

### Custom PostgreSQL Configuration

To use custom PostgreSQL settings, set the database image with your configuration:

```bash
export CLAUDE_DB_IMAGE=my-custom-postgres:latest
claude-session start
```

### Direct psql Connection

You can also connect directly using psql:

```bash
psql $DATABASE_URL
```

## Security Notes

- Databases are isolated per session using Docker networks
- Default credentials (postgres/postgres) are used for development convenience
- For production-like testing, use custom credentials via environment variables
- Database containers are not exposed to the host network by default
- `DATABASE_URL` is automatically added to `.env` (which is gitignored)

## Examples

### Full Workflow: New TypeScript Project with Database

```bash
# 1. Start a session
claude-session start myproject

# Inside the session:

# 2. Check database is ready
claude-db status

# 3. Initialize a TypeScript project
npm init -y
npm install pg @types/pg

# 4. Create a simple script
cat > index.ts <<'EOF'
import { Pool } from 'pg';

const pool = new Pool({
  connectionString: process.env.DATABASE_URL
});

async function main() {
  // Create table
  await pool.query(`
    CREATE TABLE IF NOT EXISTS users (
      id SERIAL PRIMARY KEY,
      name VARCHAR(100),
      email VARCHAR(100)
    )
  `);

  // Insert data
  await pool.query(
    'INSERT INTO users (name, email) VALUES ($1, $2)',
    ['Alice', 'alice@example.com']
  );

  // Query data
  const result = await pool.query('SELECT * FROM users');
  console.log(result.rows);

  await pool.end();
}

main();
EOF

# 5. Run it
npx tsx index.ts
```

### Backup and Restore Between Sessions

```bash
# In session 1
claude-db export ~/my-backup.sql
exit

# Start new session
claude-session start session2

# In session 2
claude-db import ~/my-backup.sql
```

## FAQ

**Q: Can I connect to the database from my host machine?**
A: By default, no. The database is only accessible within the Docker network. To expose it, you'd need to modify `claude-session.sh` to publish the port (e.g., `-p 5432:5432`).

**Q: What happens to my data when I stop a session?**
A: The data persists as long as the database container exists. Only when you delete the session is the data destroyed.

**Q: Can I use a different database (MySQL, MongoDB)?**
A: Yes! Modify the database configuration in `claude-session.sh` and change the `DB_IMAGE` and connection logic accordingly.

**Q: How do I disable databases globally?**
A: Add `export CLAUDE_DB_ENABLED=false` to your shell profile (`~/.bashrc` or `~/.zshrc`).

**Q: Can I run the database on my host instead of in a container?**
A: Yes, but you'll need to ensure the Docker containers can reach your host database and manually configure the `DATABASE_URL`.
