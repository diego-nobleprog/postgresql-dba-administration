#!/bin/bash
set -Eeuo pipefail
exec 2>&1

export LC_ALL=C
export PATH=/usr/bin:/usr/sbin:/bin:/sbin
export PGHOST=/tmp/nobleprog-p6-lab/socket
export PGPORT=5546
export PGUSER=postgres
export PGDATABASE=postgres
export PGAPPNAME=p6_runner
export PGOPTIONS="-c statement_timeout=30000"

ROOT=/tmp/nobleprog-p6-lab
DATA=$ROOT/data
E=$ROOT/evidence
PASS=0
FAIL=0
STARTED=0
RESTORE=0
CURRENT=""
POLL_OK=0
HOLDER_PID=""
HOLDER_GATE=""
HOLDER_LOG=""

declare -A RESULTS=(
    [00]=NO_PROBADO
    [01]=NO_PROBADO
    [02]=NO_PROBADO
    [03]=NO_PROBADO
    [04]=NO_PROBADO
    [05]=NO_PROBADO
)

pass() {
    PASS=$((PASS + 1))
    printf 'PASS | %s\n' "$1"
}

fail() {
    FAIL=$((FAIL + 1))
    printf 'FAIL | %s\n' "$1"
}

sql() {
    psql -X -v ON_ERROR_STOP=1 -P pager=off -e "$@"
}

q() {
    psql -X -Atq -v ON_ERROR_STOP=1 -c "$1"
}

check_sql() {
    local value
    value=$(q "$2")
    if [ "$value" = t ]; then
        pass "$1"
    else
        fail "$1; resultado=$value"
    fi
}

begin_scenario() {
    CURRENT=$1
    SCENARIO_FAIL_START=$FAIL
    RESULTS[$CURRENT]=EN_EJECUCION
    printf '\n========== ESCENARIO %s: %s ==========\n' "$1" "$2"
}

end_scenario() {
    if [ "$FAIL" -eq "$SCENARIO_FAIL_START" ]; then
        RESULTS[$CURRENT]=PASS
    else
        RESULTS[$CURRENT]=FAIL
    fi
    CURRENT=""
}

poll_sql() {
    local label=$1
    local limit=$2
    local query=$3
    local deadline=$((SECONDS + limit))
    local value

    POLL_OK=0
    while [ "$SECONDS" -lt "$deadline" ]; do
        value=$(q "$query")
        if [ "$value" = t ]; then
            POLL_OK=1
            pass "$label"
            return 0
        fi
        sleep 1
    done

    fail "$label; no se observo dentro de ${limit}s"
    return 0
}

settings_snapshot() {
    q "SELECT name || '=' || setting || '|' || COALESCE(unit,'')
       FROM pg_settings
       WHERE name IN (
         'autovacuum','autovacuum_naptime',
         'log_autovacuum_min_duration','track_counts'
       )
       ORDER BY name;"
}

options_snapshot() {
    q "SELECT c.relname || '|' ||
              COALESCE(c.reloptions::text,'NULL')
       FROM pg_class c
       JOIN pg_namespace n ON n.oid=c.relnamespace
       WHERE n.nspname='maintenance' AND c.relkind='r'
       ORDER BY c.relname;"
}

expect_error() {
    local label=$1
    local state=$2
    local statement=$3
    local name=$4
    local code

    printf '%s\n' "$statement" > "$E/$name.sql"
    printf '\nPRUEBA NEGATIVA: %s\n' "$label"

    if timeout 15 psql -X -v ON_ERROR_STOP=1 \
        -v VERBOSITY=verbose -f "$E/$name.sql" \
        > "$E/$name.log" 2>&1; then
        cat "$E/$name.log"
        fail "$label; el comando no produjo el error esperado"
    else
        code=$?
        cat "$E/$name.log"
        if [ "$code" -eq 3 ] &&
           grep -Eq "ERROR: +${state}:" "$E/$name.log"; then
            pass "$label; error esperado SQLSTATE=$state, salida=$code"
        else
            fail "$label; error inesperado, salida=$code"
        fi
    fi
}

# P6_BLOCK_03_END

start_holder() {
    local name=$1
    local relation=$2
    local input=$E/$name.sql
    local deadline
    local value

    HOLDER_GATE=$E/$name.release
    HOLDER_LOG=$E/$name.log

    value=$(q "SELECT EXISTS (
        SELECT 1 FROM pg_stat_activity
        WHERE application_name='$name'
    );")

    if [ "$value" != f ]; then
        fail "Ya existe una sesion activa llamada $name"
        exit 1
    fi

    rm -f -- "$E/$name.ready" "$HOLDER_GATE"

    cat > "$input" <<SQL
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT 'BEFORE_COUNT=' || count(*) FROM $relation;
SELECT 'BEFORE_VERSION_SUM=' || sum(version) FROM $relation;
\! touch $E/$name.ready
\! timeout 120 /usr/bin/bash $E/wait-gate.sh $HOLDER_GATE
SELECT 'AFTER_COUNT=' || count(*) FROM $relation;
SELECT 'AFTER_VERSION_SUM=' || sum(version) FROM $relation;
COMMIT;
SQL

    PGAPPNAME="$name" timeout 150 psql -X -Atq \
        -v ON_ERROR_STOP=1 -f "$input" \
        > "$HOLDER_LOG" 2>&1 &
    HOLDER_PID=$!

    deadline=$((SECONDS + 15))

    while [ "$SECONDS" -lt "$deadline" ]; do
        if [ -f "$E/$name.ready" ]; then
            value=$(q "SELECT EXISTS (
                SELECT 1 FROM pg_stat_activity
                WHERE application_name='$name'
                AND state='idle in transaction'
                AND backend_xmin IS NOT NULL
            );")

            if [ "$value" = t ]; then
                pass "$name conserva una transaccion, snapshot y senal"
                return 0
            fi
        fi

        if ! kill -0 "$HOLDER_PID" 2>/dev/null; then
            cat "$HOLDER_LOG"
            fail "La sesion $name termino antes de quedar preparada"
            exit 1
        fi

        sleep 0.2
    done

    cat "$HOLDER_LOG"
    fail "No se confirmaron conjuntamente snapshot y senal de $name"
    exit 1
}

release_holder() {
    touch "$HOLDER_GATE"

    if wait "$HOLDER_PID"; then
        pass "Sesion A finalizo con COMMIT"
    else
        fail "La sesion A termino con error"
    fi

    cat "$HOLDER_LOG"
    HOLDER_PID=""
}

# P6_BLOCK_04_END
