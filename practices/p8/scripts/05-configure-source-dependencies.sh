#!/bin/bash
# Detener ante cualquier error.
set -Eeuo pipefail

# Comprobar que trabajamos sobre desarrollo.
[[ "${P8_ROLE:-}" == "dev" ]] || exit 1

# Leer la fase de configuracion.
STAGE="${1:?Debe indicar pre o post}"

# Configurar las extensiones antes de crear los objetos.
if [[ "$STAGE" == "pre" ]]; then

    # Instalar pg_trgm en la base comercial.
    runuser -u postgres -- psql -h 127.0.0.1 -X -v ON_ERROR_STOP=1 -d ventas_db -c 'CREATE EXTENSION pg_trgm;'

    # Habilitar estadisticas de consultas en ventas.
    runuser -u postgres -- psql -h 127.0.0.1 -X -v ON_ERROR_STOP=1 -d ventas_db -c 'CREATE EXTENSION pg_stat_statements;'

    # Instalar postgres_fdw en reportes.
    runuser -u postgres -- psql -h 127.0.0.1 -X -v ON_ERROR_STOP=1 -d reportes_db -c 'CREATE EXTENSION postgres_fdw;'

    # Terminar la preparacion inicial.
    exit 0

# Configurar las dependencias despues de cargar los datos.
elif [[ "$STAGE" == "post" ]]; then

    # Ejecutar la configuracion FDW en reportes_db.
    runuser -u postgres -- psql -h 127.0.0.1 -X -v ON_ERROR_STOP=1 -d reportes_db <<'SQL'
-- Crear el schema para tablas externas.
CREATE SCHEMA externo AUTHORIZATION p8_owner;
-- Crear un servidor FDW que apunta a ventas del servidor A.
CREATE SERVER p8_ventas_server FOREIGN DATA WRAPPER postgres_fdw OPTIONS (host 'p8-dev-lab', dbname 'ventas_db', port '5432');
-- Permitir al usuario de reportes acceder al servidor FDW.
GRANT USAGE ON FOREIGN SERVER p8_ventas_server TO p8_reporter;
-- Mapear el usuario local al usuario remoto.
CREATE USER MAPPING FOR p8_reporter SERVER p8_ventas_server OPTIONS (user 'p8_reporter', password 'p8_fdw_demo_2026');
-- Crear la tabla externa de pedidos.
CREATE FOREIGN TABLE externo.pedidos (pedido_id bigint,cliente_id integer,total numeric(12,2),estado varchar(20),fecha timestamptz) SERVER p8_ventas_server OPTIONS (schema_name 'comercial',table_name 'pedidos');
-- Autorizar acceso al schema externo.
GRANT USAGE ON SCHEMA externo TO p8_reporter;
-- Autorizar consultas sobre pedidos externos.
GRANT SELECT ON externo.pedidos TO p8_reporter;
SQL

    # Terminar la configuracion de dependencias.
    exit 0

# Rechazar fases desconocidas.
else

    # Informar que la fase solicitada es invalida.
    echo 'Fase invalida de configuracion FDW' >&2

    # Interrumpir el procedimiento.
    exit 1

# Finalizar la seleccion de fase.
fi
