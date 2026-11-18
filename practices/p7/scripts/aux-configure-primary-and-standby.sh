#!/bin/bash
# ======================================================================
# ARCHIVO: aux-configure-primary-and-standby.sh
# ======================================================================
#
# OBJETIVO
# ----------------------------------------------------------------------
# Construir dos instancias PostgreSQL independientes y configurar
# la replicacion fisica entre ambas.
#
# PostgreSQL A sera el servidor principal.
# PostgreSQL B sera el servidor standby.
#
# Este archivo es utilizado durante la preparacion inicial
# y durante la reconstruccion del laboratorio.
#
# 1. CONFIGURACION COMPARTIDA
# ----------------------------------------------------------------------
# source incorpora las variables y funciones definidas en:
#
# aux-shared-environment-functions.sh
#
# Estas funciones permiten ejecutar consultas SQL, comprobar
# resultados, identificar servidores y esperar replicacion.
#
# 2. IDENTIFICACION DE LA PREPARACION
# ----------------------------------------------------------------------
# TAG=${1:-inicial} obtiene el primer argumento.
#
# Si no se proporciona ninguno, utiliza inicial.
#
# Se aceptan dos valores:
#
# inicial:
# Primera construccion del laboratorio.
#
# restaurado:
# Reconstruccion despues de completar los ejercicios.
#
# El bloque case rechaza cualquier otro valor.
#
# 3. COMPROBACIONES PREVIAS
# ----------------------------------------------------------------------
# id -un obtiene el nombre del usuario actual.
#
# El resultado debe ser postgres.
#
# Tambien se comprueba que no existan los directorios:
#
# R/A
# R/B
#
# Esto evita inicializar instancias sobre directorios
# que ya contienen datos de PostgreSQL.
#
# Si alguna condicion falla, termina la preparacion.
#
# 4. CREACION DE DIRECTORIOS
# ----------------------------------------------------------------------
# mkdir -p prepara los directorios necesarios.
#
# E:
# Contiene los registros de inicializacion y ejecucion.
#
# R/socket:
# Contiene los sockets Unix de las instancias PostgreSQL.
#
# Estos recursos forman parte del ambiente Linux.
#
# 5. INICIALIZACION DE POSTGRESQL A
# ----------------------------------------------------------------------
# initdb crea un nuevo cluster PostgreSQL.
#
# -D:
# Especifica el directorio de datos de A.
#
# --auth-local=trust:
# Permite conexiones locales sin contrasena.
#
# --auth-host=trust:
# Permite conexiones TCP autorizadas sin contrasena.
#
# --encoding=UTF8:
# Establece la codificacion UTF-8.
#
# --no-locale:
# Inicializa el cluster sin depender de una locale externa.
#
# La salida se conserva en un archivo de registro.
#
# La autenticacion trust corresponde exclusivamente
# a este laboratorio Docker aislado.
#
# 6. CONFIGURACION DE CONEXIONES
# ----------------------------------------------------------------------
# Se agregan parametros a postgresql.conf.
#
# listen_addresses=127.0.0.1
#
# Permite conexiones TCP por loopback del contenedor.
#
# port=5547
#
# Establece el puerto del servidor principal.
#
# unix_socket_directories:
#
# Indica el directorio utilizado para sockets Unix.
#
# 7. CONFIGURACION DE MEMORIA
# ----------------------------------------------------------------------
# shared_buffers=128MB
#
# Define el espacio compartido utilizado para almacenar
# paginas de datos e indices en memoria.
#
# work_mem=4MB
#
# Define la memoria base disponible para determinadas
# operaciones de ordenamiento y hash.
#
# max_connections=20
#
# Establece el numero maximo de conexiones simultaneas.
#
# 8. CONFIGURACION DE REPLICACION
# ----------------------------------------------------------------------
# wal_level=replica
#
# Habilita la informacion WAL requerida para replicacion.
#
# max_wal_senders=4
#
# Permite hasta cuatro procesos WAL Sender.
#
# max_replication_slots=4
#
# Permite crear hasta cuatro replication slots.
#
# max_slot_wal_keep_size=512MB
#
# Establece un limite de retencion de WAL por slots.
# Si el limite se supera, una replica atrasada podria
# dejar de disponer del WAL que necesita.
#
# hot_standby=on
#
# Permite ejecutar consultas de solo lectura mientras
# la instancia se encuentra en recuperacion.
#
# 9. CONFIGURACION DE ESTADISTICAS
# ----------------------------------------------------------------------
# shared_preload_libraries=pg_stat_statements
#
# Carga la biblioteca necesaria para recopilar
# estadisticas de ejecucion de sentencias SQL.
#
# compute_query_id=on
#
# Habilita la generacion de identificadores de consultas.
#
# track_io_timing=on
#
# Habilita la medicion de tiempos de operaciones I/O.
#
# 10. INICIO DE POSTGRESQL A
# ----------------------------------------------------------------------
# pg_ctl inicia el servidor principal.
#
# -D identifica su directorio de datos.
#
# -l establece el archivo de registro.
#
# -w espera hasta completar el arranque.
#
# -t 60 establece un limite de espera de 60 segundos.
#
# 11. CREACION DE LA BASE DE DATOS
# ----------------------------------------------------------------------
# psql se conecta al servidor A por el puerto 5547.
#
# La base de datos inicial utilizada es postgres.
#
# CREATE DATABASE crea nobleprog_integrado.
#
# Despues se ejecuta:
#
# aux-create-tables-and-load-sample-data.sql
#
# Este archivo crea el esquema, las tablas y los registros.
#
# 12. CREACION DE POSTGRESQL B
# ----------------------------------------------------------------------
# pg_basebackup genera una copia fisica de A.
#
# La conexion de origen utiliza:
#
# Host: 127.0.0.1
# Puerto: 5547
# Usuario: postgres
#
# application_name=integrado_B identifica la conexion.
#
# -D establece el directorio destino B.
#
# -X stream transmite WAL durante el respaldo.
#
# -R configura los archivos necesarios para que
# la instancia destino comience como standby.
#
# -C solicita crear el replication slot.
#
# -S integrado_b establece el nombre del slot fisico.
#
# --checkpoint=fast solicita un checkpoint rapido
# antes de realizar el respaldo fisico.
#
# 13. CONFIGURACION DEL PUERTO B
# ----------------------------------------------------------------------
# Se agrega port=5548 al archivo postgresql.conf de B.
#
# De esta forma, A y B pueden funcionar simultaneamente
# dentro del mismo contenedor Docker sin compartir puerto.
#
# 14. INICIO DE POSTGRESQL B
# ----------------------------------------------------------------------
# pg_ctl inicia B utilizando su directorio de datos.
#
# B comienza su proceso de recuperacion y establece
# la conexion de replicacion hacia A.
#
# 15. COMPROBACION DE IDENTIDAD
# ----------------------------------------------------------------------
# guard 5547 A comprueba el directorio de datos de A.
#
# guard 5548 B comprueba el directorio de datos de B.
#
# Esto permite verificar que las consultas posteriores
# se ejecutan contra las instancias correctas.
#
# 16. COMPROBACION DE SINCRONIZACION
# ----------------------------------------------------------------------
# sync_replica obtiene una posicion WAL de A.
#
# Despues espera hasta que B haya reproducido
# los cambios correspondientes a esa posicion.
#
# No realiza una copia manual de registros.
#
# 17. COMPROBACION DE ROLES
# ----------------------------------------------------------------------
# pg_is_in_recovery() identifica el estado del servidor.
#
# Resultado esperado en A:
#
# false
#
# Significa que A funciona como servidor principal.
#
# Resultado esperado en B:
#
# true
#
# Significa que B funciona como standby.
#
# 18. COMPROBACION DE CARGA
# ----------------------------------------------------------------------
# Se consulta la cantidad de registros de negocio.pedidos.
#
# Resultado esperado en A:
#
# 50004
#
# Resultado esperado en B:
#
# 50004
#
# Esto demuestra que ambas instancias tienen los
# registros iniciales del laboratorio.
#
# 19. COMPROBACION DE TOTALES
# ----------------------------------------------------------------------
# Se utiliza total_sql para sumar pedidos PAGADOS
# de la fecha 2026-01-15.
#
# Resultado esperado en A:
#
# 900
#
# Resultado esperado en B:
#
# 900
#
# 20. COMPROBACION DEL INDICE
# ----------------------------------------------------------------------
# to_regclass comprueba la existencia del indice:
#
# negocio.pedidos_estado_fecha_idx
#
# El indice no debe existir inicialmente.
#
# Se creara durante el escenario 07.01 para comparar
# el rendimiento de la consulta BEFORE y AFTER.
#
# 21. RESULTADO ESPERADO
# ----------------------------------------------------------------------
# PostgreSQL A funcionando como PRIMARY.
#
# PostgreSQL B funcionando como STANDBY.
#
# Replicacion fisica configurada.
#
# 50004 pedidos cargados en ambas instancias.
#
# Total inicial de pedidos pagados: 900.
#
# Indice experimental ausente.
#
# Laboratorio preparado para el escenario 07.01.
#
# ARCHIVOS RELACIONADOS
# ----------------------------------------------------------------------
# aux-shared-environment-functions.sh
# aux-create-tables-and-load-sample-data.sql
# aux-initialize-docker-container.sh
#
# ======================================================================

source /tmp/p7-integrado-scripts/aux-shared-environment-functions.sh

TAG=${1:-inicial}
case "$TAG" in inicial|restaurado) ;; *) exit 1;; esac

test "$(id -un)" = postgres
test ! -e "$R/A"
test ! -e "$R/B"
mkdir -p "$E" "$R/socket"

initdb -D "$R/A" --auth-local=trust --auth-host=trust \
    --encoding=UTF8 --no-locale > "$E/initdb-$TAG.log" 2>&1

cat >> "$R/A/postgresql.conf" <<CONF
listen_addresses='127.0.0.1'
port=5547
unix_socket_directories='$R/socket'
shared_buffers='128MB'
work_mem='4MB'
max_connections=20
wal_level=replica
max_wal_senders=4
max_replication_slots=4
max_slot_wal_keep_size='512MB'
shared_preload_libraries='pg_stat_statements'
compute_query_id=on
track_io_timing=on
hot_standby=on
CONF

pg_ctl -D "$R/A" -l "$E/A-$TAG.log" -w -t 60 start

psql -X -h 127.0.0.1 -p 5547 -U postgres -d postgres \
    -v ON_ERROR_STOP=1 -c "CREATE DATABASE $DB"

sql 5547 -e -f "$S/aux-create-tables-and-load-sample-data.sql"

pg_basebackup \
    -d 'host=127.0.0.1 port=5547 user=postgres application_name=integrado_B' \
    -D "$R/B" -X stream -R -C -S integrado_b --checkpoint=fast

printf '\nport=5548\n' >> "$R/B/postgresql.conf"

pg_ctl -D "$R/B" -l "$E/B-$TAG.log" -w -t 60 start

guard 5547 A
guard 5548 B
sync_replica

check 'A principal' 5547 'SELECT pg_is_in_recovery()' f
check 'B standby' 5548 'SELECT pg_is_in_recovery()' t
check 'Carga inicial A' 5547 \
    'SELECT count(*) FROM negocio.pedidos' 50004
check 'Carga inicial B' 5548 \
    'SELECT count(*) FROM negocio.pedidos' 50004
check 'Total inicial A' 5547 "$total_sql" 900
check 'Total inicial B' 5548 "$total_sql" 900
check 'Indice experimental ausente' 5547 \
    "SELECT to_regclass('negocio.pedidos_estado_fecha_idx') IS NULL" t
