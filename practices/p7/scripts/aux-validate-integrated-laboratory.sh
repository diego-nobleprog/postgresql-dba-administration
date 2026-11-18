#!/bin/bash
# ======================================================================
# ARCHIVO: aux-validate-integrated-laboratory.sh
# ======================================================================
#
# OBJETIVO
# ----------------------------------------------------------------------
# Comprobar automaticamente el funcionamiento de los tres
# escenarios integrados y la restauracion del laboratorio.
#
# Este script ejecuta una secuencia completa de verificaciones
# de rendimiento, replicacion, concurrencia y promocion.
#
# No sustituye la ejecucion guiada de los participantes.
#
# 1. CONFIGURACION INICIAL
# ----------------------------------------------------------------------
# source incorpora las funciones y variables compartidas.
#
# STAGE identifica la etapa actualmente ejecutada.
#
# S1, S2 y S3 representan los resultados de los escenarios.
#
# RESTORE representa el resultado de la restauracion.
#
# BG_A y BG_B almacenan identificadores de procesos
# utilizados para simular sesiones concurrentes.
#
# 2. PREPARACION DE RESULTADOS
# ----------------------------------------------------------------------
# mkdir -p crea el directorio E.
#
# En este directorio se guardan registros de consultas,
# planes de ejecucion y resultados de las comprobaciones.
#
# 3. FUNCION finish()
# ----------------------------------------------------------------------
# Esta funcion se ejecuta al finalizar el script.
#
# Recupera el codigo de salida de la ejecucion.
#
# Desactiva su propio manejador EXIT para evitar
# que vuelva a ejecutarse durante el cierre.
#
# Si existen procesos de sesiones concurrentes,
# intenta terminarlos y esperar su finalizacion.
#
# Posteriormente ejecuta:
#
# aux-stop-postgresql-instances.sh
#
# Finalmente genera un resumen que contiene:
#
# - Etapa alcanzada.
# - Resultado del escenario 1.
# - Resultado del escenario 2.
# - Resultado del escenario 3.
# - Resultado de la restauracion.
# - Codigo final de ejecucion.
#
# 4. MANEJADORES DE FINALIZACION
# ----------------------------------------------------------------------
# trap finish EXIT ejecuta finish cuando termina el script.
#
# El manejador ERR informa la etapa y linea asociadas
# a un error de ejecucion.
#
# Esto facilita identificar en que operacion fallo
# una comprobacion automatizada.
#
# 5. PREPARACION INICIAL
# ----------------------------------------------------------------------
# Se ejecuta:
#
# aux-configure-primary-and-standby.sh
#
# Se crean PostgreSQL A y B con los datos originales.
#
# 6. ESCENARIO 1 - CONSULTA ORIGINAL
# ----------------------------------------------------------------------
# Se ejecuta el reporte de pedidos pagados.
#
# Se obtiene el plan de la consulta mediante EXPLAIN.
#
# Despues se ejecuta:
#
# EXPLAIN (ANALYZE, BUFFERS)
#
# El resultado se conserva como plan BEFORE.
#
# 7. ESCENARIO 1 - CREACION DEL INDICE
# ----------------------------------------------------------------------
# Se crea el indice:
#
# pedidos_estado_fecha_idx
#
# Este indice utiliza las columnas:
#
# estado
# fecha
#
# Posteriormente se repite EXPLAIN ANALYZE con BUFFERS.
#
# Se conserva el plan AFTER.
#
# Se comprueba que el plan posterior mencione el indice.
#
# El total de negocio debe continuar siendo 900.
#
# 8. ESCENARIO 1 - ESTADISTICAS
# ----------------------------------------------------------------------
# Se ejecuta tres veces la consulta individual de pedidos.
#
# Posteriormente se consulta pg_stat_statements.
#
# Se revisan valores como:
#
# - calls.
# - rows.
# - total_exec_time.
# - shared_blks_hit.
# - shared_blks_read.
#
# Se verifica que la consulta tenga al menos tres llamadas.
#
# 9. ESCENARIO 1 - COMPROBACION DE REPLICA
# ----------------------------------------------------------------------
# Se espera la sincronizacion de PostgreSQL B.
#
# Se comprueba que el indice tambien exista en B.
#
# El total de pedidos pagados debe seguir siendo 900.
#
# Se ejecuta EXPLAIN ANALYZE con BUFFERS sobre B.
#
# Tambien se intenta ejecutar un UPDATE en el standby.
#
# La escritura debe ser rechazada.
#
# Se verifica el SQLSTATE 25006 correspondiente
# a una transaccion de solo lectura.
#
# 10. ESCENARIO 2 - POSICION WAL INICIAL
# ----------------------------------------------------------------------
# Se obtiene pg_current_wal_lsn() en PostgreSQL A.
#
# Esta posicion sirve como referencia para medir
# la generacion posterior de WAL.
#
# 11. ESCENARIO 2 - SESION A
# ----------------------------------------------------------------------
# Se prepara una secuencia SQL que ejecuta:
#
# BEGIN.
#
# UPDATE del pedido 101 a PAGADO.
#
# Consulta del total desde la misma transaccion.
#
# La sesion debe observar un total de 1100.
#
# Despues se mantiene la transaccion abierta
# hasta recibir una señal de liberacion.
#
# Finalmente ejecuta COMMIT.
#
# 12. ESCENARIO 2 - VISIBILIDAD MVCC
# ----------------------------------------------------------------------
# Mientras A mantiene su transaccion abierta:
#
# Otra conexion al principal debe observar 900.
#
# La replica tambien debe observar 900.
#
# Esto demuestra que los cambios no confirmados
# no son visibles para esas conexiones.
#
# 13. ESCENARIO 2 - SESION B
# ----------------------------------------------------------------------
# Se inicia otra conexion identificada como p7_sesion_B.
#
# Esta conexion intenta actualizar el mismo pedido 101.
#
# Se establece statement_timeout de 60 segundos.
#
# La operacion debe quedar esperando el bloqueo
# mantenido por la transaccion de la sesion A.
#
# 14. ESCENARIO 2 - DIAGNOSTICO DEL BLOQUEO
# ----------------------------------------------------------------------
# Se utiliza pg_stat_activity para localizar las sesiones.
#
# pg_blocking_pids identifica el proceso bloqueador.
#
# wait_event_type debe indicar Lock en la sesion B.
#
# Tambien se consulta pg_locks para observar:
#
# - PID.
# - Tipo de bloqueo.
# - Modalidad.
# - Estado de concesion.
#
# 15. ESCENARIO 2 - LIBERACION
# ----------------------------------------------------------------------
# Se libera la espera de la sesion A.
#
# La transaccion A ejecuta COMMIT.
#
# La sesion B puede completar su UPDATE.
#
# Se espera la terminacion de ambas conexiones.
#
# El total confirmado en el principal debe ser 1100.
#
# Despues se comprueba que B tambien alcance 1100.
#
# 16. ESCENARIO 2 - NUEVO PEDIDO
# ----------------------------------------------------------------------
# Se inserta el pedido 105.
#
# Cliente: Luis.
# Estado: PAGADO.
# Importe: 100.
#
# El total del principal pasa de 1100 a 1200.
#
# Se espera la replicacion.
#
# El total de B tambien debe ser 1200.
#
# 17. ESCENARIO 2 - DIAGNOSTICO WAL
# ----------------------------------------------------------------------
# pg_wal_lsn_diff calcula el avance WAL
# respecto a la posicion obtenida inicialmente.
#
# Se consulta pg_stat_checkpointer para revisar
# estadisticas relacionadas con checkpoints.
#
# Se consulta pg_stat_replication para observar
# el estado de la conexion de replicacion.
#
# Se consulta pg_replication_slots para comprobar
# los slots existentes y su actividad.
#
# 18. ESCENARIO 3 - FALLA DEL PRINCIPAL
# ----------------------------------------------------------------------
# Se ejecuta:
#
# 02-simulate-primary-server-failure.sh
#
# Este script verifica la sincronizacion y detiene A.
#
# B debe continuar disponible como standby.
#
# 19. ESCENARIO 3 - PROMOCION
# ----------------------------------------------------------------------
# Se ejecuta:
#
# pg_promote(true,30)
#
# Esta funcion solicita la promocion de B y espera
# hasta 30 segundos para su finalizacion.
#
# Posteriormente se consulta pg_is_in_recovery().
#
# El resultado esperado es false.
#
# Esto confirma que B funciona como nuevo PRIMARY.
#
# 20. ESCENARIO 3 - CONTINUIDAD
# ----------------------------------------------------------------------
# Se comprueba que el indice experimental siga presente.
#
# Se inserta el pedido 106:
#
# Cliente: Ana.
# Estado: PAGADO.
# Importe: 300.
#
# El total de pedidos pagados debe ser 1500.
#
# La cantidad de pedidos pagados recientes debe ser seis.
#
# Se ejecuta el reporte agrupado.
#
# Tambien se ejecuta EXPLAIN ANALYZE con BUFFERS
# sobre el servidor promovido.
#
# 21. RESTAURACION
# ----------------------------------------------------------------------
# Se ejecuta:
#
# 03-restore-initial-laboratory-state.sh
#
# Este archivo reconstruye PostgreSQL A y B
# con sus datos y roles originales.
#
# Si la restauracion termina correctamente,
# RESTORE recibe el valor PASS.
#
# 22. FINALIZACION
# ----------------------------------------------------------------------
# Se actualiza STAGE a FINALIZADO.
#
# Al terminar se ejecuta finish.
#
# Se detienen las instancias que permanezcan activas
# y se escribe el resumen consolidado.
#
# 23. RESULTADO ESPERADO
# ----------------------------------------------------------------------
# Escenario 1: PASS.
#
# Escenario 2: PASS.
#
# Escenario 3: PASS.
#
# Restauracion: PASS.
#
# Codigo final: 0.
#
# IMPORTANTE
# ----------------------------------------------------------------------
# La validacion automatizada comprueba condiciones concretas.
#
# No sustituye la interpretacion de los planes,
# las estadisticas, los bloqueos y la replicacion
# que deben realizar los participantes.
#
# ARCHIVOS RELACIONADOS
# ----------------------------------------------------------------------
# aux-shared-environment-functions.sh
# aux-configure-primary-and-standby.sh
# aux-query-recent-paid-orders.sql
# aux-report-paid-orders-by-customer.sql
# 02-simulate-primary-server-failure.sh
# 03-restore-initial-laboratory-state.sh
# aux-stop-postgresql-instances.sh
#
# ======================================================================

source /tmp/p7-integrado-scripts/aux-shared-environment-functions.sh

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

    bash "$S/aux-stop-postgresql-instances.sh"
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

bash "$S/aux-configure-primary-and-standby.sh"

STAGE=ESCENARIO_1

sql 5547 -e -f "$S/aux-report-paid-orders-by-customer.sql"
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
    sql 5547 -e -f "$S/aux-query-recent-paid-orders.sql"
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

bash "$S/02-simulate-primary-server-failure.sh"

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

sql 5548 -e -f "$S/aux-report-paid-orders-by-customer.sql"
sql 5548 -e -c "EXPLAIN (ANALYZE,BUFFERS) $plan"
test ! -f "$R/A/postmaster.pid"

S3=PASS
STAGE=RESTAURACION

bash "$S/03-restore-initial-laboratory-state.sh"

RESTORE=PASS
STAGE=FINALIZADO
