#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

CONFIG_FILE="${CONFIG_FILE:-/etc/postgresql-backup-recovery.conf}"
BACKUP_FILE=""
TARGET_DATABASE=""
DROP_EXISTING=0
CONFIRM_DATABASE=""

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fatal() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  postgresql-restore.sh --backup FILE --database NAME [options]

Required:
  --backup FILE          Custom-format pg_dump file to restore.
  --database NAME        Target PostgreSQL database.

Options:
  --config FILE          Configuration file path.
  --drop-existing        Drop and recreate the target database first.
  --confirm NAME         Required with --drop-existing; must exactly match NAME.
  -h, --help             Show this help.

Examples:
  postgresql-restore.sh \
    --backup /srv/backups/app/2026-09-15_02-00-00-app.dump \
    --database app_restore_test

  postgresql-restore.sh \
    --backup /srv/backups/app/2026-09-15_02-00-00-app.dump \
    --database app \
    --drop-existing \
    --confirm app
EOF
}

parse_args() {
    while (($#)); do
        case "$1" in
            --backup)
                (($# >= 2)) || fatal '--backup requires a value.'
                BACKUP_FILE=$2
                shift 2
                ;;
            --database)
                (($# >= 2)) || fatal '--database requires a value.'
                TARGET_DATABASE=$2
                shift 2
                ;;
            --config)
                (($# >= 2)) || fatal '--config requires a value.'
                CONFIG_FILE=$2
                shift 2
                ;;
            --drop-existing)
                DROP_EXISTING=1
                shift
                ;;
            --confirm)
                (($# >= 2)) || fatal '--confirm requires a value.'
                CONFIRM_DATABASE=$2
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                fatal "Unknown argument: $1"
                ;;
        esac
    done

    [[ -n "${BACKUP_FILE}" ]] || fatal '--backup is required.'
    [[ -n "${TARGET_DATABASE}" ]] || fatal '--database is required.'
    [[ ${TARGET_DATABASE} =~ ^[A-Za-z0-9_.-]+$ ]] || fatal 'Unsupported target database name.'
    [[ -r "${BACKUP_FILE}" ]] || fatal "Backup file is not readable: ${BACKUP_FILE}"

    if ((DROP_EXISTING)); then
        [[ "${CONFIRM_DATABASE}" == "${TARGET_DATABASE}" ]] \
            || fatal '--drop-existing requires --confirm with the exact target database name.'
    fi
}

load_config() {
    [[ -r "${CONFIG_FILE}" ]] || fatal "Configuration file is not readable: ${CONFIG_FILE}"

    # shellcheck disable=SC1090
    source "${CONFIG_FILE}"

    : "${PGHOST:=127.0.0.1}"
    : "${PGPORT:=5432}"
    : "${PGUSER:=postgres}"

    export PGHOST PGPORT PGUSER
    if [[ -n "${PGPASSFILE:-}" ]]; then
        export PGPASSFILE
    fi
}

verify_backup() {
    local checksum_file="${BACKUP_FILE}.sha256"

    log 'Validating PostgreSQL dump structure.'
    pg_restore --list "${BACKUP_FILE}" >/dev/null

    if [[ -r "${checksum_file}" ]]; then
        log 'Validating SHA-256 checksum.'
        (
            cd "$(dirname "${BACKUP_FILE}")"
            sha256sum --check --status "$(basename "${checksum_file}")"
        ) || fatal 'Backup checksum verification failed.'
    else
        log "Checksum file not found; continuing after pg_restore structural validation: ${checksum_file}"
    fi
}

database_exists() {
    psql \
        --dbname=postgres \
        --tuples-only \
        --no-align \
        --command="SELECT 1 FROM pg_database WHERE datname = :'dbname';" \
        --set="dbname=${TARGET_DATABASE}" \
        | grep -qx '1'
}

prepare_database() {
    if database_exists; then
        if ((DROP_EXISTING)); then
            log "Terminating active sessions for '${TARGET_DATABASE}'."
            psql \
                --dbname=postgres \
                --set="dbname=${TARGET_DATABASE}" \
                --command="SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = :'dbname' AND pid <> pg_backend_pid();" \
                >/dev/null

            log "Dropping database '${TARGET_DATABASE}'."
            dropdb --if-exists "${TARGET_DATABASE}"
            createdb "${TARGET_DATABASE}"
        else
            fatal "Target database '${TARGET_DATABASE}' already exists. Use a new database or --drop-existing --confirm ${TARGET_DATABASE}."
        fi
    else
        log "Creating target database '${TARGET_DATABASE}'."
        createdb "${TARGET_DATABASE}"
    fi
}

restore_database() {
    log "Restoring '${BACKUP_FILE}' into '${TARGET_DATABASE}'."
    pg_restore \
        --exit-on-error \
        --no-owner \
        --dbname="${TARGET_DATABASE}" \
        "${BACKUP_FILE}"

    log "Running post-restore connectivity check for '${TARGET_DATABASE}'."
    psql \
        --dbname="${TARGET_DATABASE}" \
        --tuples-only \
        --no-align \
        --command='SELECT current_database();' \
        | grep -qx "${TARGET_DATABASE}" \
        || fatal 'Post-restore validation failed.'
}

main() {
    parse_args "$@"
    load_config

    command -v pg_restore >/dev/null 2>&1 || fatal 'pg_restore is required.'
    command -v psql >/dev/null 2>&1 || fatal 'psql is required.'
    command -v createdb >/dev/null 2>&1 || fatal 'createdb is required.'
    command -v dropdb >/dev/null 2>&1 || fatal 'dropdb is required.'
    command -v sha256sum >/dev/null 2>&1 || fatal 'sha256sum is required.'

    verify_backup
    prepare_database
    restore_database
    log 'Restore completed successfully.'
}

main "$@"
