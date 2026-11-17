#!/bin/bash
source /tmp/p7-integrado-scripts/00-env.sh

guard 5547 A
guard 5548 B
check 'A principal' 5547 'SELECT pg_is_in_recovery()' f
check 'B standby' 5548 'SELECT pg_is_in_recovery()' t
check 'A tiene 1200' 5547 "$total_sql" 1200

sync_replica
check 'B tiene 1200' 5548 "$total_sql" 1200
stop_cluster A

if pg_isready -h 127.0.0.1 -p 5547 -U postgres -d "$DB"; then
    echo 'FAIL | A sigue disponible'
    exit 1
else
    rc=$?
    test "$rc" -eq 2
fi

echo 'A DETENIDO; B AUN ES STANDBY. AHORA PUEDE PROMOVERSE B.'
