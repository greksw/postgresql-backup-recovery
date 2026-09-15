# PostgreSQL Backup & Recovery Toolkit

A small operational toolkit for repeatable PostgreSQL logical backups and controlled restores on Linux.

The project was rebuilt from an older production-oriented backup script into a safer portfolio-grade workflow with explicit configuration, checksum validation, retention, concurrency protection, and guarded restore operations.

## What it solves

The toolkit covers two related operational tasks:

- scheduled logical backups of one or more PostgreSQL databases;
- controlled restoration of a selected dump into a new or explicitly confirmed target database.

It intentionally does **not** manage CIFS/NFS mounts, Telegram credentials, or storage passwords. Remote backup storage should be mounted independently by the operating system, systemd, automount, or another infrastructure layer.

## Design

```text
PostgreSQL
   |
   | pg_dump --format=custom
   v
local / mounted backup filesystem
   |
   +-- database-a/
   |    +-- 2026-09-15_02-00-00-database-a.dump
   |    +-- 2026-09-15_02-00-00-database-a.dump.sha256
   |
   +-- database-b/
        +-- ...

Restore path:
.dump -> checksum validation -> pg_restore structural validation
      -> create target DB or explicitly confirmed replacement
      -> pg_restore --exit-on-error -> connectivity validation
```

## Repository structure

```text
.
├── README.md
├── config/
│   └── postgresql-backup-recovery.conf.example
├── scripts/
│   ├── postgresql-backup.sh
│   └── postgresql-restore.sh
└── .github/
    └── workflows/
        └── lint.yml
```

## Safety model

The v2 implementation deliberately avoids several patterns from the legacy scripts:

- no database passwords embedded in shell code;
- no CIFS passwords passed on the command line;
- no world-writable `0777` backup directories;
- no automatic `dropdb` during a normal restore;
- no blind pipeline such as `pg_dump | gzip > file` without validating the result;
- no backup file publication before `pg_dump` and `pg_restore --list` succeed;
- no concurrent backup runs against the same configured job.

If password authentication is required, use `PGPASSFILE` with file mode `0600`. For local execution, peer authentication is preferable when it fits the environment.

## Requirements

- Linux
- Bash 4+
- PostgreSQL client utilities:
  - `pg_dump`
  - `pg_restore`
  - `psql`
  - `createdb`
  - `dropdb`
- `flock`
- `sha256sum`

The PostgreSQL client major version should normally be equal to or newer than the server version being backed up.

## Installation

Copy the scripts to a root-managed location:

```bash
sudo install -m 0750 scripts/postgresql-backup.sh /usr/local/sbin/postgresql-backup
sudo install -m 0750 scripts/postgresql-restore.sh /usr/local/sbin/postgresql-restore
```

Install the example configuration:

```bash
sudo install -m 0640 \
  config/postgresql-backup-recovery.conf.example \
  /etc/postgresql-backup-recovery.conf
```

Edit the configuration and replace the example database names and paths.

## Authentication

For local PostgreSQL instances, peer authentication is usually the cleanest option for a service account with only the required privileges.

If a password is required, create `/etc/postgresql-backup-recovery.pgpass`:

```text
127.0.0.1:5432:*:backup_user:REPLACE_ME
```

Then restrict it:

```bash
sudo chmod 0600 /etc/postgresql-backup-recovery.pgpass
```

Do not commit real `.pgpass` files or credentials to Git.

## Backup

Run manually:

```bash
sudo /usr/local/sbin/postgresql-backup
```

Or specify another configuration file:

```bash
sudo /usr/local/sbin/postgresql-backup /etc/postgresql-backup-recovery.conf
```

For every configured database, the script:

1. acquires an exclusive `flock` lock;
2. writes a custom-format dump to a temporary file inside the target filesystem;
3. validates the dump with `pg_restore --list`;
4. atomically renames the validated dump into its final filename;
5. creates a SHA-256 checksum file;
6. applies the configured retention policy.

Example output:

```text
/srv/postgresql-backups/app_db/
├── 2026-09-15_02-00-00-app_db.dump
└── 2026-09-15_02-00-00-app_db.dump.sha256
```

## Restore

Restore into a new test database:

```bash
sudo /usr/local/sbin/postgresql-restore \
  --backup /srv/postgresql-backups/app_db/2026-09-15_02-00-00-app_db.dump \
  --database app_db_restore_test
```

If the target database already exists, the script refuses to overwrite it.

Replacing an existing database requires two explicit flags, including the exact database name:

```bash
sudo /usr/local/sbin/postgresql-restore \
  --backup /srv/postgresql-backups/app_db/2026-09-15_02-00-00-app_db.dump \
  --database app_db \
  --drop-existing \
  --confirm app_db
```

This is intentional protection against accidental destructive restores.

## Validation

Before a backup is published:

```bash
pg_restore --list backup.dump
```

A SHA-256 sidecar file is then generated for later integrity verification.

During restore, the toolkit checks:

- custom dump readability;
- SHA-256 checksum when a sidecar checksum exists;
- target database safety conditions;
- `pg_restore --exit-on-error` result;
- successful connection to the restored database.

A backup should still be considered operationally valid only after periodic restore testing in an isolated environment.

## Scheduling

A typical systemd timer or cron job can invoke `/usr/local/sbin/postgresql-backup`. The script contains its own `flock` protection, so overlapping scheduled executions are rejected.

For production use, systemd units are preferable because they provide explicit identities, dependencies, logging, resource controls, and failure handling.

## Storage

The toolkit expects `BACKUP_ROOT` to already be available.

Examples:

- local ZFS/ext4/XFS storage;
- NFS mounted by systemd;
- CIFS mounted through a root-only credentials file;
- a dedicated backup filesystem replicated or protected independently.

Mount lifecycle and storage credentials are deliberately kept outside the backup script.

## Security considerations

- keep backup files readable only by the backup operator/service account;
- never use `file_mode=0777` or `dir_mode=0777` for database backup storage;
- do not expose database passwords in shell arguments or repository files;
- use a dedicated PostgreSQL role with the minimum required privileges;
- protect backup storage independently from the database server;
- test restores regularly;
- encrypt backup storage or transport when the data classification requires it.

## Limitations

This repository implements logical backup and restore with `pg_dump`/`pg_restore`. It is not a replacement for:

- physical base backups;
- WAL archiving;
- Point-in-Time Recovery (PITR);
- PostgreSQL HA/replication;
- enterprise backup products.

For large databases or strict RPO/RTO requirements, physical backups and WAL-based recovery should be evaluated.

## Legacy migration

Earlier repository versions mixed PostgreSQL backup logic, CIFS mounting, plaintext credentials, Telegram notifications, and retention in one script. The v2 branch intentionally separates these concerns and removes embedded environment-specific values.

The original Git history is retained to show the evolution from an operational script toward a safer and more reusable design.

## License

A license has not yet been selected. Add one before treating the repository as a reusable open-source project.
