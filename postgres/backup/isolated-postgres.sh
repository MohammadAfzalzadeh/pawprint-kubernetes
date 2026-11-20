# Start a local-only PostgreSQL server for an offline restore.
start_isolated_postgres() {
  # Drop any inherited libpq configuration before selecting the private socket.
  local setting
  for setting in "${!PG@}"; do unset "$setting"; done
  export PGHOST=/restore/socket PGPORT=5432 PGUSER=postgres LC_ALL=C
  restore_pgdata=${1:-/restore/data}
  umask 077
  if [[ -e "$restore_pgdata/PG_VERSION" ]]; then
    echo 'Refusing to initialize over an existing PostgreSQL cluster' >&2
    return 1
  fi
  install -d -o postgres -g postgres -m 0700 "$restore_pgdata" "$PGHOST"
  gosu postgres initdb --pgdata="$restore_pgdata" --locale=en_US.utf8 --encoding=UTF8 \
    --auth-local=peer --auth-host=scram-sha-256 --no-instructions
  gosu postgres pg_ctl -D "$restore_pgdata" \
    -o "-c listen_addresses='' -c unix_socket_directories=$PGHOST -c shared_buffers=24MB -c max_connections=10" -w start
  trap 'gosu postgres pg_ctl -D "$restore_pgdata" -m fast -w stop' EXIT
}
