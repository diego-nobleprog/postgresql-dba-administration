#!/bin/bash
source /tmp/p7-integrado-scripts/00-env.sh

STAGE=PREPARACION
S1=NO_PROBADO
S2=NO_PROBADO
S3=NO_PROBADO
RESTORE=NO_PROBADO
BG_A=''
BG_B=''
mkdir -p "$E"

finish() {
    local rc=$?
    trap - EXIT
    set +e

    if [ -n "$BG_A" ]; then
        kill "$BG_A" 2>/dev/null
        wait "$BG_A" 2>/dev/null
    fi
    if [ -n "$BG_B" ]; then
        kill "$BG_B" 2>/dev/null
        wait "$BG_B" 2>/dev/null
    fi

    bash "$S/99-cleanup-lab.sh"
    if [ "$?" -ne 0 ]; then rc=1; fi

    {
        echo "ETAPA FINAL: $STAGE"
        echo "ESCENARIO 1: $S1"
        echo "ESCENARIO 2: $S2"
        echo "ESCENARIO 3: $S3"
        echo "RESTAURACION: $RESTORE"
        echo "CODIGO FINAL: $rc"
        echo 'Modalidad automatizada; no acredita recorrido interactivo.'
    } | tee "$E/resumen.txt"

    exit "$rc"
}

trap finish EXIT
trap 'echo "ERROR | etapa=$STAGE | linea=$LINENO"' ERR

bash "$S/00-prepare-lab.sh"

STAGE=ESCENARIO_1

sql 5547 -e -f "$S/01-report.sql"
sql 5547 -e -c "EXPLAIN $plan"
sql 5547 -e -c "EXPLAIN (ANALYZE,BUFFERS) $plan" \
    | tee "$E/plan-before.txt"

sql 5547 -e -c "
    CREATE INDEX pedidos_estado_fecha_idx
    ON negocio.pedidos(estado,fecha);"

sql 5547 -e -c "EXPLAIN (ANALYZE,BUFFERS) $plan" \
    | tee "$E/plan-after.txt"

grep -q 'pedidos_estado_fecha_idx' "$E/plan-after.txt"
check 'Resultado A conservado' 5547 "$total_sql" 900

for n in 1 2 3; do
    sql 5547 -e -f "$S/01-query.sql"
done

sql 5547 -e -c "
    SELECT calls,rows,total_exec_time,
           shared_blks_hit,shared_blks_read,query
    FROM pg_stat_statements
    WHERE query LIKE 'SELECT c.nombre,p.id%'
    ORDER BY calls DESC;"

check 'Reporte en pg_stat_statements' 5547 "
    SELECT EXISTS(
        SELECT 1 FROM pg_stat_statements
        WHERE query LIKE 'SELECT c.nombre,p.id%' AND calls>=3
    )" t

sync_replica

check 'Indice recibido en B' 5548 \
    "SELECT to_regclass('negocio.pedidos_estado_fecha_idx') IS NOT NULL" t
check 'Resultado B conservado' 5548 "$total_sql" 900

sql 5548 -e -c "EXPLAIN (ANALYZE,BUFFERS) $plan"

if sql 5548 -v VERBOSITY=verbose \
    -c "UPDATE negocio.pedidos SET estado='PAGADO' WHERE id=101" \
    > "$E/solo-lectura.log" 2>&1; then
    echo 'FAIL | B acepto escritura'
    exit 1
else
    rc=$?
    cat "$E/solo-lectura.log"
    test "$rc" -eq 1
    grep -Eq 'ERROR: +25006:' "$E/solo-lectura.log"
fi

S1=PASS
STAGE=ESCENARIO_2
WAL_BEFORE=$(q 5547 'SELECT pg_current_wal_lsn()')

cat > "$E/A.sql" <<SQL
BEGIN;
UPDATE negocio.pedidos SET estado='PAGADO' WHERE id=101;
SELECT 'TOTAL_A=' || sum(total)::integer
FROM negocio.pedidos
WHERE estado='PAGADO' AND fecha=DATE '2026-01-15';
\! touch $E/A.ready
\! timeout 90 bash -c 'until test -f $E/A.release; do sleep 0.2; done'
COMMIT;
SQL

PGAPPNAME=p7_sesion_A timeout 100 \
    psql -X -h 127.0.0.1 -p 5547 -U postgres -d "$DB" \
    -At -v ON_ERROR_STOP=1 -f "$E/A.sql" \
    > "$E/A.log" 2>&1 &
BG_A=$!

end=$((SECONDS+30))
until test -f "$E/A.ready"; do
    if ! kill -0 "$BG_A" 2>/dev/null; then
        cat "$E/A.log"
        exit 1
    fi
    test "$SECONDS" -lt "$end"
    sleep 0.2
done

poll 'A mantiene su transaccion' 5547 "
    SELECT EXISTS(
        SELECT 1 FROM pg_stat_activity
        WHERE application_name='p7_sesion_A'
          AND state='idle in transaction'
    )"

check 'Otra conexion ve 900' 5547 "$total_sql" 900
check 'Standby ve 900 sin COMMIT' 5548 "$total_sql" 900

PGAPPNAME=p7_sesion_B timeout 75 \
    psql -X -h 127.0.0.1 -p 5547 -U postgres -d "$DB" \
    -v ON_ERROR_STOP=1 \
    -c "SET statement_timeout='60s'; UPDATE negocio.pedidos SET estado='PAGADO' WHERE id=101;" \
    > "$E/B.log" 2>&1 &
BG_B=$!

poll 'B espera el bloqueo de A' 5547 "
    SELECT EXISTS(
        SELECT 1
        FROM pg_stat_activity b
        JOIN pg_stat_activity a ON a.pid=ANY(pg_blocking_pids(b.pid))
        WHERE b.application_name='p7_sesion_B'
          AND a.application_name='p7_sesion_A'
          AND b.wait_event_type='Lock'
    )"

sql 5547 -e -c "
    SELECT pid,application_name,state,wait_event_type,wait_event,
           pg_blocking_pids(pid)
    FROM pg_stat_activity
    WHERE application_name LIKE 'p7_sesion_%';

    SELECT l.pid,l.locktype,l.mode,l.granted
    FROM pg_locks l
    JOIN pg_stat_activity a USING(pid)
    WHERE a.application_name LIKE 'p7_sesion_%';"

touch "$E/A.release"

wait "$BG_A"
BG_A=''
wait "$BG_B"
BG_B=''

cat "$E/A.log" "$E/B.log"
grep -q 'TOTAL_A=1100' "$E/A.log"

check 'Total confirmado A' 5547 "$total_sql" 1100
sync_replica
check 'B recibio 1100' 5548 "$total_sql" 1100

sql 5547 -e -c "
    INSERT INTO negocio.pedidos
    VALUES(105,2,'2026-01-15','PAGADO',100);"

sync_replica
check 'A muestra 1200' 5547 "$total_sql" 1200
check 'B muestra 1200' 5548 "$total_sql" 1200

check 'Sin sesiones A/B' 5547 "
    SELECT count(*) FROM pg_stat_activity
    WHERE application_name LIKE 'p7_sesion_%'" 0

sql 5547 -e -c "
    SELECT pg_wal_lsn_diff(
        pg_current_wal_lsn(),'$WAL_BEFORE'::pg_lsn
    ) AS wal_bytes;
    SELECT * FROM pg_stat_checkpointer;
    SELECT application_name,state,sync_state,sent_lsn,replay_lsn
    FROM pg_stat_replication;
    SELECT slot_name,active FROM pg_replication_slots;"

check 'WAL avanzo' 5547 \
    "SELECT pg_current_wal_lsn()>'$WAL_BEFORE'::pg_lsn" t

S2=PASS
STAGE=ESCENARIO_3

bash "$S/03-stop-primary.sh"

check 'Promocion completada' 5548 'SELECT pg_promote(true,30)' t
check 'B es principal' 5548 'SELECT pg_is_in_recovery()' f
check 'Indice conservado' 5548 \
    "SELECT to_regclass('negocio.pedidos_estado_fecha_idx') IS NOT NULL" t

sql 5548 -e -c "
    INSERT INTO negocio.pedidos
    VALUES(106,1,'2026-01-15','PAGADO',300);"

check 'Total final 1500' 5548 "$total_sql" 1500
check 'Seis pagados recientes' 5548 "
    SELECT count(*) FROM negocio.pedidos
    WHERE estado='PAGADO' AND fecha=DATE '2026-01-15'" 6

sql 5548 -e -f "$S/01-report.sql"
sql 5548 -e -c "EXPLAIN (ANALYZE,BUFFERS) $plan"
test ! -f "$R/A/postmaster.pid"

S3=PASS
STAGE=RESTAURACION

bash "$S/98-reset-lab.sh"

RESTORE=PASS
STAGE=FINALIZADO
