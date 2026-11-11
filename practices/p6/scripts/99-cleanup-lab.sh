#!/bin/bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/00-env.sh"
export PGDATABASE=nobleprog_maintenance_scenarios

if [ "$(id -un)" != postgres ]; then
    echo "ERROR: ejecutar como usuario postgres."
    exit 1
fi

for file in "$DATA/PG_VERSION" "$E/restore.sql" \
            "$E/settings.before" "$E/options.before" \
            "$E/postgresql.auto.conf.before"; do
    if [ ! -f "$file" ]; then
        echo "ERROR: falta un archivo necesario: $file"
        exit 1
    fi
done

pg_ctl -D "$DATA" status

touch "$E/p6_mvcc_A.release" "$E/p6_bloat_A.release"

if q "SELECT pg_terminate_backend(pid)
      FROM pg_stat_activity
      WHERE datname=current_database()
      AND backend_type='client backend'
      AND pid<>pg_backend_pid();" > "$E/manual-session-cleanup.log" 2>&1; then
    pass "Sesiones del laboratorio cerradas"
else
    fail "No se pudo confirmar el cierre de sesiones"
fi

if psql -X -v ON_ERROR_STOP=1 -f "$E/restore.sql"; then
    pass "Opciones de tablas restauradas"
else
    fail "Error al restaurar opciones de tablas"
fi

if cp "$E/postgresql.auto.conf.before" "$DATA/postgresql.auto.conf"; then
    if q "SELECT pg_reload_conf();"; then
        pass "Configuracion original repuesta y recarga solicitada"
    else
        fail "Error al solicitar recarga"
    fi
else
    fail "Error al restaurar postgresql.auto.conf"
fi

settings_ok=0
for attempt in {1..10}; do
    if settings_snapshot > "$E/settings.after" &&
       cmp -s "$E/settings.before" "$E/settings.after"; then
        settings_ok=1
        break
    fi
    sleep 1
done

if [ "$settings_ok" -eq 1 ]; then
    pass "Configuracion global igual a BEFORE"
else
    fail "Configuracion global diferente de BEFORE"
    diff -u "$E/settings.before" "$E/settings.after" || true
fi

if options_snapshot > "$E/options.after" &&
   cmp -s "$E/options.before" "$E/options.after"; then
    pass "Opciones de tablas iguales a BEFORE"
else
    fail "Opciones de tablas diferentes de BEFORE"
    diff -u "$E/options.before" "$E/options.after" || true
fi

if pg_ctl -D "$DATA" -m fast -w -t 30 stop; then
    pass "PostgreSQL detenido"
else
    fail "No se pudo confirmar la detencion"
fi

printf '\nCIERRE: PASS=%s FAIL=%s\n' "$PASS" "$FAIL"

if [ "$FAIL" -ne 0 ]; then
    exit 1
fi

echo "CIERRE CORRECTO: configuracion restaurada e instancia detenida."
echo "Los datos y evidencias se conservan dentro del contenedor."
