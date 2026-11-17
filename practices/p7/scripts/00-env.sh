#!/bin/bash
set -Eeuo pipefail
export LC_ALL=C
export PATH=/usr/bin:/usr/sbin:/bin:/sbin
unset PGOPTIONS PGSERVICE PGSERVICEFILE PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD
export PGCONNECT_TIMEOUT=5

R=/tmp/nobleprog-p7-integrado
E=$R/evidence
S=/tmp/p7-integrado-scripts
DB=nobleprog_integrado

sql() {
    psql -X -h 127.0.0.1 -p "$1" -U postgres -d "$DB" \
        -v ON_ERROR_STOP=1 -P pager=off "${@:2}"
}

q() {
    sql "$1" -Atq -c "$2"
}

check() {
    local result
    result=$(q "$2" "$3")
    if [ "$result" != "$4" ]; then
        echo "FAIL | $1 | esperado=$4 | obtenido=$result"
        return 1
    fi
    echo "PASS | $1"
}

poll() {
    local end=$((SECONDS+45)) result
    while [ "$SECONDS" -lt "$end" ]; do
        result=$(q "$2" "$3")
        if [ "$result" = t ]; then
            echo "PASS | $1"
            return 0
        fi
        sleep 0.2
    done
    echo "FAIL | Timeout: $1"
    return 1
}

guard() {
    local node=$2
    check 'Directorio de datos exclusivo' "$1" \
        'SHOW data_directory' "$R/$node"
}

stop_cluster() {
    if [ -f "$R/$1/postmaster.pid" ]; then
        pg_ctl -D "$R/$1" -m fast -w -t 30 stop
    fi
    test ! -f "$R/$1/postmaster.pid"
}

sync_replica() {
    local lsn
    lsn=$(q 5547 'SELECT pg_current_wal_lsn()')
    poll 'B aplico el WAL confirmado en A' 5548 \
        "SELECT pg_last_wal_replay_lsn()>='$lsn'::pg_lsn"
}

total_sql="SELECT sum(total)::integer FROM negocio.pedidos
WHERE estado='PAGADO' AND fecha=DATE '2026-01-15'"

plan="SELECT c.nombre,p.id,p.fecha,p.total
FROM negocio.pedidos p
JOIN negocio.clientes c ON c.id=p.cliente_id
WHERE p.estado='PAGADO' AND p.fecha=DATE '2026-01-15'
ORDER BY p.fecha,p.id"
