# Authentik Backup & Restore

## Backup

### Database Backup

```bash
docker exec helix-postgres pg_dump -U postgres authentik > /data/backups/authentik-$(date +%Y%m%d).sql
```

**Verify**:
```bash
ls -lh /data/backups/authentik-*.sql
# Should show a file with reasonable size (typically 1-10 MB)

head -5 /data/backups/authentik-$(date +%Y%m%d).sql
# Should show SQL statements, not errors
```

### Media Backup

Authentik stores uploaded media (icons, backgrounds, custom CSS) in `/data/authentik/`.

```bash
tar czf /data/backups/authentik-media-$(date +%Y%m%d).tar.gz /data/authentik/
```

### Automated Daily Backup (Cron)

```bash
crontab -e
```

Add:
```cron
# Authentik DB backup — daily at 3:00 AM
0 3 * * * docker exec helix-postgres pg_dump -U postgres authentik > /data/backups/authentik-$(date +\%Y\%m\%d).sql 2>/dev/null

# Authentik media backup — daily at 3:15 AM
15 3 * * * tar czf /data/backups/authentik-media-$(date +\%Y\%m\%d).tar.gz /data/authentik/ 2>/dev/null

# Prune backups older than 30 days — daily at 4:00 AM
0 4 * * * find /data/backups/ -name "authentik-*" -mtime +30 -delete 2>/dev/null
```

**Verify cron is active**:
```bash
crontab -l | grep authentik
```

### Backup Directory Setup

```bash
mkdir -p /data/backups
```

---

## Restore

### Full Restore Procedure

**When to use**: Authentik database is corrupted, config is broken beyond repair, or migrating to a new server.

#### 1. Stop Authentik

```bash
docker compose -f docker-compose/authentik/docker-compose.yml down
```

#### 2. Drop and Recreate Database

```bash
docker exec -i helix-postgres psql -U postgres <<EOF
DROP DATABASE IF EXISTS authentik;
CREATE DATABASE authentik;
EOF
```

#### 3. Import Backup

```bash
docker exec -i helix-postgres psql -U postgres authentik < /data/backups/authentik-YYYYMMDD.sql
```

Replace `YYYYMMDD` with the date of the backup you want to restore.

#### 4. Restore Media (if needed)

```bash
# Remove current media
rm -rf /data/authentik/media /data/authentik/templates

# Extract backup
tar xzf /data/backups/authentik-media-YYYYMMDD.tar.gz -C /
```

#### 5. Restart Authentik

```bash
docker compose -f docker-compose/authentik/docker-compose.yml up -d
```

#### 6. Verify Recovery

```bash
# Check containers are healthy
docker ps | grep authentik
# Both authentik-server and authentik-worker should be "Up" and "(healthy)"

# Check logs for errors
docker logs authentik-server --tail 30

# Test the UI
curl -I https://auth.helixstax.net
# Expected: 200 or 302

# Test SSO flow
# Open https://auth.helixstax.net in browser
# Login with @helixstax.com Google account
# Should succeed with all providers and applications intact
```

#### 7. Verify Downstream Services

After Authentik restore, verify SSO still works for dependent services:

```bash
# Netbird — open https://vpn.helixstax.net, should redirect to Authentik SSO
# Grafana — check SSO login (if configured)
# Devtron — check SSO login (if configured)
```

---

## Troubleshooting

### "role authentik does not exist" on restore

The backup may reference a different database user. Check the backup header:

```bash
head -20 /data/backups/authentik-YYYYMMDD.sql | grep "Owner"
```

If it references user `authentik` instead of `postgres`, create the role:

```bash
docker exec -i helix-postgres psql -U postgres -c "CREATE ROLE authentik WITH LOGIN PASSWORD 'temp';"
```

Then re-run the import.

### Authentik stuck in crash loop after restore

Check if migrations need to run:

```bash
docker logs authentik-server --tail 50
```

If you see migration errors, the backup may be from a different Authentik version. Ensure the Authentik image version matches the backup version.

### Backup file is empty or very small

The `pg_dump` command may have failed silently. Run it interactively to see errors:

```bash
docker exec -it helix-postgres pg_dump -U postgres authentik | head -20
```

Common cause: wrong database user. The compose file uses `POSTGRES_USER=postgres`, so `pg_dump -U postgres` is correct.
