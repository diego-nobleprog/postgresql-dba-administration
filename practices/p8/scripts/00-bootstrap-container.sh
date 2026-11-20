#!/bin/bash
# Detener el proceso ante errores y variables no definidas.
set -Eeuo pipefail

# Comprobar que Docker Compose definio el rol.
: "${P8_ROLE:?Falta P8_ROLE}"
# Comprobar que existe la variable del directorio persistente.
: "${P8_HOME:?Falta P8_HOME}"
# Comprobar que existe la variable PGDATA.
: "${PGDATA:?Falta PGDATA}"

# Rechazar roles diferentes de desarrollo y produccion.
[[ "$P8_ROLE" == "dev" || "$P8_ROLE" == "prod" ]] || exit 1

# Verificar que el bootstrap se ejecuta con root.
[[ "$(id -u)" -eq 0 ]] || exit 1

# Validar la sintaxis de los scripts auxiliares.
for script in /opt/p8/scripts/*.sh; do
    # Comprobar sintaxis Bash sin ejecutar el archivo.
    bash -n "$script"
done

# Preparar directorios de almacenamiento y sockets.
mkdir -p "$P8_HOME" /var/run/postgresql

# Asignar los directorios al usuario postgres.
chown postgres:postgres "$P8_HOME" /var/run/postgresql

# Establecer permisos del directorio de sockets.
chmod 775 /var/run/postgresql

# Rechazar un directorio de datos incompleto.
[[ ! -d "$PGDATA" || -s "$PGDATA/PG_VERSION" ]] || exit 1

# Comprobar si PostgreSQL ya fue inicializado.
if [[ ! -s "$PGDATA/PG_VERSION" ]]; then

    # Inicializar PostgreSQL con UTF-8 y locale C.
    runuser -u postgres -- initdb -D "$PGDATA" --encoding=UTF8 --locale=C --auth-local=trust --auth-host=trust

    # Agregar la configuracion del laboratorio.
    cat >> "$PGDATA/postgresql.conf" <<'PGCONF'
# Permitir conexiones dentro de la red privada de P8.
listen_addresses = '*'
# Utilizar el puerto PostgreSQL estandar.
port = 5432
# Configurar el directorio de sockets.
unix_socket_directories = '/var/run/postgresql'
# Definir el numero maximo de conexiones.
max_connections = 40
# Configurar la memoria compartida del motor.
shared_buffers = '128MB'
# Definir memoria por operacion de ordenamiento.
work_mem = '4MB'
# Habilitar WAL para replicacion logica.
wal_level = logical
# Permitir emisores WAL para futuras pruebas.
max_wal_senders = 4
# Permitir slots de replicacion.
max_replication_slots = 4
# Precargar las estadisticas de sentencias.
shared_preload_libraries = 'pg_stat_statements'
# Habilitar identificadores de consultas.
compute_query_id = on
# Registrar tiempos de lectura y escritura.
track_io_timing = on
# Registrar esperas por bloqueos.
log_lock_waits = on
# Registrar consultas que superen medio segundo.
log_min_duration_statement = 500
PGCONF

    # Exigir SCRAM al usuario FDW al consultar ventas_db.
    # Esta regla tiene prioridad sobre las reglas trust del laboratorio.
    runuser -u postgres -- sed -i '1i\host ventas_db p8_reporter 0.0.0.0/0 scram-sha-256' "$PGDATA/pg_hba.conf"

    # Iniciar PostgreSQL para preparar su contenido.
    runuser -u postgres -- pg_ctl -D "$PGDATA" -l "$P8_HOME/bootstrap.log" -w -t 60 start

    # Habilitar estadisticas en la base administrativa.
    runuser -u postgres -- psql -h 127.0.0.1 -X -v ON_ERROR_STOP=1 -d postgres -c 'CREATE EXTENSION IF NOT EXISTS pg_stat_statements;'

    # Seleccionar la configuracion de desarrollo.
    if [[ "$P8_ROLE" == "dev" ]]; then

        # Crear los roles, las bases y el tablespace.
        bash /opt/p8/scripts/01-configure-development.sh

        # Instalar las extensiones de las bases de negocio.
        bash /opt/p8/scripts/05-configure-source-dependencies.sh pre

        # Crear tablas, indices, vistas, funciones y triggers.
        runuser -u postgres -- psql -h 127.0.0.1 -X -v ON_ERROR_STOP=1 -d ventas_db -f /opt/p8/scripts/03-create-source-objects.sql

        # Cargar los registros iniciales del sistema comercial.
        runuser -u postgres -- psql -h 127.0.0.1 -X -v ON_ERROR_STOP=1 -d ventas_db -f /opt/p8/scripts/04-load-source-data.sql

        # Configurar la dependencia FDW entre las bases.
        bash /opt/p8/scripts/05-configure-source-dependencies.sh post

    # Seleccionar la configuracion de produccion.
    else

        # Verificar que produccion no contiene bases comerciales.
        bash /opt/p8/scripts/02-configure-production.sh

    # Terminar la seleccion de servidor.
    fi

    # Crear el marcador de inicializacion terminada.
    runuser -u postgres -- touch "$P8_HOME/.p8-ready"

    # Ejecutar las verificaciones del ambientado.
    if ! bash /opt/p8/scripts/06-validate-environment.sh "$P8_ROLE"; then

        # Eliminar el marcador si la validacion falla.
        rm -f "$P8_HOME/.p8-ready"

        # Interrumpir el arranque ante un ambiente incorrecto.
        exit 1

    # Finalizar la validacion.
    fi

    # Detener PostgreSQL para arrancarlo como proceso principal.
    runuser -u postgres -- pg_ctl -D "$PGDATA" -m fast -w -t 60 stop

# Controlar el reinicio de un cluster previamente ambientado.
else

    # Exigir el marcador de un ambientado completo.
    [[ -f "$P8_HOME/.p8-ready" ]] || exit 1

# Finalizar la comprobacion de inicializacion.
fi

# Ejecutar PostgreSQL como proceso principal del contenedor.
exec runuser -u postgres -- postgres -D "$PGDATA"
