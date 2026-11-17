#!/bin/bash
source /tmp/p7-integrado-scripts/00-env.sh

guard 5548 B
check 'B promovido' 5548 'SELECT pg_is_in_recovery()' f
check 'Total final antes de reconstruir' 5548 "$total_sql" 1500

test ! -f "$R/A/postmaster.pid"
test ! -e "$R/A-ejecutado"
test ! -e "$R/B-ejecutado"

stop_cluster B
mv "$R/A" "$R/A-ejecutado"
mv "$R/B" "$R/B-ejecutado"

bash "$S/00-prepare-lab.sh" restaurado

check 'Indice experimental ausente en B' 5548 \
    "SELECT to_regclass('negocio.pedidos_estado_fecha_idx') IS NULL" t
check 'Cuatro pedidos recientes' 5547 \
    "SELECT count(*) FROM negocio.pedidos WHERE fecha=DATE '2026-01-15'" 4
check 'Sin sesiones del ejercicio' 5547 \
    "SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE 'p7_sesion_%'" 0

echo 'ESTADO INICIAL RECONSTRUIDO; A Y B SIGUEN ENCENDIDOS.'
