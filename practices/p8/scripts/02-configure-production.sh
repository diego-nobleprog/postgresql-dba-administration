#!/bin/bash
# Detener el proceso ante errores.
set -Eeuo pipefail

# Comprobar que trabajamos en produccion.
[[ "${P8_ROLE:-}" == "prod" ]] || exit 1

# Verificar que ventas_db no existe.
runuser -u postgres -- psql -h 127.0.0.1 -X -v ON_ERROR_STOP=1 -d postgres -At -c "SELECT count(*) FROM pg_database WHERE datname='ventas_db';" | grep -qx '0'

# Verificar que reportes_db no existe.
runuser -u postgres -- psql -h 127.0.0.1 -X -v ON_ERROR_STOP=1 -d postgres -At -c "SELECT count(*) FROM pg_database WHERE datname='reportes_db';" | grep -qx '0'

# Verificar que sandbox_db no existe.
runuser -u postgres -- psql -h 127.0.0.1 -X -v ON_ERROR_STOP=1 -d postgres -At -c "SELECT count(*) FROM pg_database WHERE datname='sandbox_db';" | grep -qx '0'

# Confirmar que produccion espera la migracion.
echo 'P8_PRODUCTION_TARGET_READY=1'
