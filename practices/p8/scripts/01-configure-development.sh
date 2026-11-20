#!/bin/bash
# Detener el proceso ante errores.
set -Eeuo pipefail

# Comprobar que trabajamos en desarrollo.
[[ "${P8_ROLE:-}" == "dev" ]] || exit 1

# Crear el directorio fisico del tablespace.
mkdir -p "$P8_HOME/tablespaces/indices"

# Asignar el tablespace al usuario postgres.
chown -R postgres:postgres "$P8_HOME/tablespaces"

# Restringir los permisos de los indices.
chmod 700 "$P8_HOME/tablespaces/indices"

# Crear el rol propietario de los objetos.
runuser -u postgres -- psql -h 127.0.0.1 -X -v ON_ERROR_STOP=1 -d postgres -c 'CREATE ROLE p8_owner NOLOGIN;'

# Crear el usuario de la aplicacion.
runuser -u postgres -- psql -h 127.0.0.1 -X -v ON_ERROR_STOP=1 -d postgres -c 'CREATE ROLE p8_app LOGIN;'

# Crear el usuario de consultas.
runuser -u postgres -- psql -h 127.0.0.1 -X -v ON_ERROR_STOP=1 -d postgres -c 'CREATE ROLE p8_reader LOGIN;'

# Crear el usuario de reportes.
runuser -u postgres -- psql -h 127.0.0.1 -X -v ON_ERROR_STOP=1 -d postgres -c "CREATE ROLE p8_reporter LOGIN PASSWORD 'p8_fdw_demo_2026';"

# Crear un tablespace ubicado en una ruta personalizada.
runuser -u postgres -- psql -h 127.0.0.1 -X -v ON_ERROR_STOP=1 -d postgres -c "CREATE TABLESPACE p8_ts_indices LOCATION '$P8_HOME/tablespaces/indices';"

# Permitir al propietario utilizar el tablespace.
runuser -u postgres -- psql -h 127.0.0.1 -X -v ON_ERROR_STOP=1 -d postgres -c 'GRANT CREATE ON TABLESPACE p8_ts_indices TO p8_owner;'

# Crear la base de datos principal.
runuser -u postgres -- psql -h 127.0.0.1 -X -v ON_ERROR_STOP=1 -d postgres -c 'CREATE DATABASE ventas_db OWNER p8_owner;'

# Crear la base de reportes.
runuser -u postgres -- psql -h 127.0.0.1 -X -v ON_ERROR_STOP=1 -d postgres -c 'CREATE DATABASE reportes_db OWNER p8_owner;'

# Crear la base de pruebas que no sera migrada.
runuser -u postgres -- psql -h 127.0.0.1 -X -v ON_ERROR_STOP=1 -d postgres -c 'CREATE DATABASE sandbox_db OWNER p8_owner;'

# Crear una tabla exclusiva de la base de pruebas.
runuser -u postgres -- psql -h 127.0.0.1 -X -v ON_ERROR_STOP=1 -d sandbox_db -c 'CREATE TABLE public.notas_prueba (id integer PRIMARY KEY, nota text NOT NULL);'

# Agregar un registro que identifique la base excluida.
runuser -u postgres -- psql -h 127.0.0.1 -X -v ON_ERROR_STOP=1 -d sandbox_db -c "INSERT INTO public.notas_prueba VALUES (1, 'NO MIGRAR');"

# Confirmar que las bases y roles fueron creados.
echo 'P8_DEVELOPMENT_DATABASES_READY=1'
