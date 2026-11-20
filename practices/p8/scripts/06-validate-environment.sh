#!/bin/bash
# Detener la validacion ante cualquier error.
set -Eeuo pipefail

# Obtener el rol del servidor.
ROLE="${1:?Debe indicar dev o prod}"

# Validar que corresponde al contenedor actual.
[[ "$ROLE" == "${P8_ROLE:-}" ]] || exit 1

# Comprobar que existe el marcador del ambientado.
[[ -f "${P8_HOME:?}/.p8-ready" ]] || exit 1

# Verificar que PostgreSQL responde.
runuser -u postgres -- pg_isready -h 127.0.0.1 -p 5432 -U postgres >/dev/null

# Obtener el numero de version PostgreSQL.
VERSION="$(runuser -u postgres -- psql -h 127.0.0.1 -X -v ON_ERROR_STOP=1 -d postgres -At -c 'SHOW server_version_num;')"

# Comprobar que utilizamos PostgreSQL 18.
[[ "$VERSION" -ge 180000 && "$VERSION" -lt 190000 ]] || exit 1

# Verificar las extensiones disponibles en el software.
[[ "$(runuser -u postgres -- psql -h 127.0.0.1 -X -v ON_ERROR_STOP=1 -d postgres -At -c "SELECT count(*) FROM pg_available_extensions WHERE name IN ('pg_trgm','postgres_fdw','pg_stat_statements');")" == '3' ]] || exit 1

# Verificar que el servidor utiliza el PGDATA esperado.
[[ "$(runuser -u postgres -- psql -h 127.0.0.1 -X -v ON_ERROR_STOP=1 -d postgres -At -c 'SHOW data_directory;')" == "$PGDATA" ]] || exit 1

# Verificar que el WAL permite replicacion logica.
[[ "$(runuser -u postgres -- psql -h 127.0.0.1 -X -v ON_ERROR_STOP=1 -d postgres -At -c 'SHOW wal_level;')" == 'logical' ]] || exit 1

# Identificar el servidor de desarrollo.
if [[ "$ROLE" == "dev" ]]; then

    # Verificar que existen las tres bases de origen.
    [[ "$(runuser -u postgres -- psql -h 127.0.0.1 -X -v ON_ERROR_STOP=1 -d postgres -At -c "SELECT count(*) FROM pg_database WHERE datname IN ('ventas_db','reportes_db','sandbox_db');")" == '3' ]] || exit 1

    # Verificar que existen los cuatro roles.
    [[ "$(runuser -u postgres -- psql -h 127.0.0.1 -X -v ON_ERROR_STOP=1 -d postgres -At -c "SELECT count(*) FROM pg_roles WHERE rolname IN ('p8_owner','p8_app','p8_reader','p8_reporter');")" == '4' ]] || exit 1

    # Verificar que existen los tres schemas comerciales.
    [[ "$(runuser -u postgres -- psql -h 127.0.0.1 -X -v ON_ERROR_STOP=1 -d ventas_db -At -c "SELECT count(*) FROM pg_namespace WHERE nspname IN ('comercial','reportes','auditoria');")" == '3' ]] || exit 1

    # Verificar los dos pedidos originales.
    [[ "$(runuser -u postgres -- psql -h 127.0.0.1 -X -v ON_ERROR_STOP=1 -d ventas_db -At -c 'SELECT count(*) FROM comercial.pedidos;')" == '2' ]] || exit 1

    # Verificar que los pedidos suman 1900.
    [[ "$(runuser -u postgres -- psql -h 127.0.0.1 -X -v ON_ERROR_STOP=1 -d ventas_db -At -c 'SELECT sum(total) FROM comercial.pedidos;')" == '1900.00' ]] || exit 1

    # Comprobar que se creo el tablespace adicional.
    [[ "$(runuser -u postgres -- psql -h 127.0.0.1 -X -v ON_ERROR_STOP=1 -d postgres -At -c "SELECT count(*) FROM pg_tablespace WHERE spcname='p8_ts_indices';")" == '1' ]] || exit 1

    # Comprobar que el indice utiliza el tablespace.
    [[ "$(runuser -u postgres -- psql -h 127.0.0.1 -X -v ON_ERROR_STOP=1 -d ventas_db -At -c "SELECT count(*) FROM pg_class i JOIN pg_tablespace t ON t.oid=i.reltablespace WHERE i.relname='idx_pedidos_estado' AND t.spcname='p8_ts_indices';")" == '1' ]] || exit 1

    # Verificar la extension de busqueda por trigramas.
    [[ "$(runuser -u postgres -- psql -h 127.0.0.1 -X -v ON_ERROR_STOP=1 -d ventas_db -At -c "SELECT count(*) FROM pg_extension WHERE extname='pg_trgm';")" == '1' ]] || exit 1

    # Verificar el indice GIN.
    [[ "$(runuser -u postgres -- psql -h 127.0.0.1 -X -v ON_ERROR_STOP=1 -d ventas_db -At -c "SELECT count(*) FROM pg_indexes WHERE indexname='idx_productos_nombre_trgm';")" == '1' ]] || exit 1

    # Comprobar el trigger de auditoria.
    [[ "$(runuser -u postgres -- psql -h 127.0.0.1 -X -v ON_ERROR_STOP=1 -d ventas_db -At -c "SELECT count(*) FROM pg_trigger WHERE tgname='trg_pedido_estado' AND NOT tgisinternal;")" == '1' ]] || exit 1

    # Verificar la funcion de total de pedido.
    [[ "$(runuser -u postgres -- psql -h 127.0.0.1 -X -v ON_ERROR_STOP=1 -d ventas_db -At -c 'SELECT comercial.total_pedido(5001);')" == '700.00' ]] || exit 1

    # Verificar el procedimiento de pago.
    [[ "$(runuser -u postgres -- psql -h 127.0.0.1 -X -v ON_ERROR_STOP=1 -d ventas_db -At -c "SELECT count(*) FROM pg_proc WHERE proname='registrar_pago' AND prokind='p';")" == '1' ]] || exit 1

    # Verificar los datos de la vista materializada.
    [[ "$(runuser -u postgres -- psql -h 127.0.0.1 -X -v ON_ERROR_STOP=1 -d ventas_db -At -c 'SELECT count(*) FROM reportes.mv_ventas_pagadas;')" == '2' ]] || exit 1

    # Comprobar que el FDW permite consultar pedidos.
    [[ "$(runuser -u postgres -- psql -h 127.0.0.1 -X -v ON_ERROR_STOP=1 -U p8_reporter -d reportes_db -At -c 'SELECT count(*) FROM externo.pedidos;')" == '2' ]] || exit 1

    # Comprobar que la base de pruebas contiene su registro.
    [[ "$(runuser -u postgres -- psql -h 127.0.0.1 -X -v ON_ERROR_STOP=1 -d sandbox_db -At -c 'SELECT count(*) FROM public.notas_prueba;')" == '1' ]] || exit 1

# Identificar el servidor de produccion.
else

    # Comprobar que no existen bases comerciales.
    [[ "$(runuser -u postgres -- psql -h 127.0.0.1 -X -v ON_ERROR_STOP=1 -d postgres -At -c "SELECT count(*) FROM pg_database WHERE datname IN ('ventas_db','reportes_db','sandbox_db');")" == '0' ]] || exit 1

    # Comprobar que no se migraron los roles de negocio.
    [[ "$(runuser -u postgres -- psql -h 127.0.0.1 -X -v ON_ERROR_STOP=1 -d postgres -At -c "SELECT count(*) FROM pg_roles WHERE rolname IN ('p8_owner','p8_app','p8_reader','p8_reporter');")" == '0' ]] || exit 1

# Finalizar la validacion del servidor.
fi

# Confirmar que el ambiente fue preparado correctamente.
echo "P8_${ROLE^^}_ENVIRONMENT_PASS=1"
