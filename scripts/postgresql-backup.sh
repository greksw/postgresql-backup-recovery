#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

CONFIG_FILE="${1:-/etc/postgresql-backup-recovery.conf}"
LOCK_FD=9
TMP_FILES=()

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fatal() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    local tmp
    for tmp in "${TMP_FILES[@]:-}"; do
        [[ -n "${tmp}" ]] && rm -f -- "${tmp}"
    done
}

trap cleanup EXIT

require_command() {
    command -v "$1" >/dev/null 2>&1 || fatal "Required command not found: $1"
}

load_config() {
    [[ -r "${CONFIG_FILE}" ]] || fatal "Configuration file is not readable: ${CONFIG_FILE}"

    # shellcheck disable=SC1090
    source "${CONFIG_FILE}"

    : "${BACKUP_ROOT:?BACKUP_ROOT must be set in ${CONFIG_FILE}}"
    : "${RETENTION_DAYS:=30}"
    : "${LOCK_FILE:=/run/lock/postgresql-backup-recovery.lock}"
    : "${PGHOST:=127.0.0.1}"
    : "${PGPORT:=5432}"
    : "${PGUSER:=postgres}"

    [[ ${RETENTION_DAYS} =~ ^[0-9]+$ ]] || fatal 'RETENTION_DAYS must be a non-negative integer.'
    declare -p DATABASES >/dev/null 2>&1 || fatal 'DATABASES must be declared as a Bash array.'
    ((${#DATABASES[@]} > 0)) || fatal 'DATABASES must contain at least one database name.'

    export PGHOST PGPORT PGUSER
    if [[ -n "${PGPASSFILE:-}" ]]; then
        export PGPASSFILE
    fi
}

acquire_lock() {
    install -d -m 0755 "$(dirname "${LOCK_FILE}")"
    eval "exec ${LOCK_FD}>\"${LOCK_FILE}\""
    flock -n "${LOCK_FD}" || fatal 'Another backup process is already running.'
}

validate_database_name() {
    local database=$1
    [[ ${database} =~ ^[A-Za-z0-9_.-]+$ ]] \
        || fatal "Unsupported database name for filesystem-safe backup naming: ${database}"
}

backup_database() {
    local database=$1
    local timestamp=$2
    local database_dir final_file temp_file checksum_file

    validate_database_name "${database}"

    database_dir="${BACKUP_ROOT}/${database}"
    final_file="${database_dir}/${timestamp}-${database}.dump"
    checksum_file="${final_file}.sha256"

    install -d -m 0750 "${database_dir}"
    temp_file=$(mktemp --tmpdir="${database_dir}" ".${database}.XXXXXX.dump")
    TMP_FILES+=("${temp_file}")

    log "Backing up database '${database}'."
    pg_dump \
        --format=custom \
        --file="${temp_file}" \
        --dbname="${database}"

    log "Validating dump structure for '${database}'."
    pg_restore --list "${temp_file}" >/dev/null

    chmod 0640 "${temp_file}"
    mv -- "${temp_file}" "${final_file}"
    TMP_FILES=()

    (
        cd "${database_dir}"
        sha256sum "$(basename "${final_file}")" > "$(basename "${checksum_file}")"
    )
    chmod 0640 "${checksum_file}"

    log "Backup completed: ${final_file}"
}

prune_old_backups() {
    local database database_dir

    for database in "${DATABASES[@]}"; do
        database_dir="${BACKUP_ROOT}/${database}"
        [[ -d "${database_dir}" ]] || continue

        find "${database_dir}" \
            -type f \
            \( -name '*.dump' -o -name '*.dump.sha256' \) \
            -mtime "+${RETENTION_DAYS}" \
            -print \
            -delete
    done
}

main() {
    require_command pg_dump
    require_command pg_restore
    require_command sha256sum
    require_command flock

    load_config
    acquire_lock

    install -d -m 0750 "${BACKUP_ROOT}"

    local timestamp database
    timestamp=$(date '+%Y-%m-%d_%H-%M-%S')

    for database in "${DATABASES[@]}"; do
        backup_database "${database}" "${timestamp}"
    done

    log "Applying retention policy: ${RETENTION_DAYS} days."
    prune_old_backups
    log 'Backup run completed successfully.'
}

main "$@"
