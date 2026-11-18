#!/bin/bash
# ======================================================================
# ARCHIVO: aux-shared-environment-functions.sh
# ======================================================================
#
# OBJETIVO
# ----------------------------------------------------------------------
# Centralizar las variables, consultas y funciones reutilizadas
# por los scripts del laboratorio integrado.
#
# Este archivo no representa un ejercicio independiente.
# Los demas scripts lo incorporan mediante source.
#
# 1. CONFIGURACION DE BASH
# ----------------------------------------------------------------------
# set -Eeuo pipefail habilita comprobaciones de errores.
#
# LC_ALL=C establece un entorno regional consistente
# para la ejecucion de herramientas y mensajes.
#
# PATH define las ubicaciones de los ejecutables Linux.
#
# 2. LIMPIEZA DE VARIABLES DE POSTGRESQL
# ----------------------------------------------------------------------
# unset elimina posibles configuraciones heredadas:
#
# PGOPTIONS
# PGSERVICE
# PGSERVICEFILE
# PGHOST
# PGPORT
# PGDATABASE
# PGUSER
# PGPASSWORD
#
# Esto evita que las conexiones utilicen accidentalmente
# valores diferentes de los definidos por el laboratorio.
#
# PGCONNECT_TIMEOUT=5 limita a cinco segundos
# la espera para establecer una conexion PostgreSQL.
#
# 3. VARIABLES PRINCIPALES
# ----------------------------------------------------------------------
# R identifica el directorio principal del laboratorio.
#
# E identifica el directorio de resultados dentro de R.
#
# S identifica el directorio de scripts.
#
# DB establece el nombre de la base de datos:
#
# nobleprog_integrado
#
# Estas variables permiten reutilizar las mismas rutas
# y conexiones en diferentes archivos.
#
# 4. FUNCION sql()
# ----------------------------------------------------------------------
# Ejecuta consultas mediante psql.
#
# El primer argumento indica el puerto PostgreSQL.
#
# Los argumentos restantes se entregan a psql.
#
# Opciones importantes:
#
# - -X: evita cargar configuraciones personales de psql.
# - -h: utiliza 127.0.0.1.
# - -p: selecciona el puerto recibido.
# - -U: utiliza el usuario postgres.
# - -d: selecciona nobleprog_integrado.
# - ON_ERROR_STOP=1: convierte errores SQL en fallos.
# - pager=off: desactiva la paginacion interactiva.
#
# 5. FUNCION q()
# ----------------------------------------------------------------------
# Ejecuta una consulta SQL y devuelve un resultado compacto.
#
# Utiliza las opciones -Atq de psql:
#
# - -A: salida sin formato alineado.
# - -t: elimina encabezados y pies de tabla.
# - -q: reduce mensajes informativos.
#
# Es utilizada para comparar valores concretos,
# como cantidades, estados y posiciones WAL.
#
# 6. FUNCION check()
# ----------------------------------------------------------------------
# Recibe una descripcion, puerto, consulta y valor esperado.
#
# Ejecuta la consulta y compara el resultado obtenido
# con el valor esperado.
#
# Si coinciden, muestra PASS.
#
# Si son diferentes, muestra FAIL y devuelve error.
#
# Ejemplo conceptual:
#
# Valor esperado: 900.
# Valor obtenido: 900.
# Resultado: PASS.
#
# 7. FUNCION poll()
# ----------------------------------------------------------------------
# Repite una consulta hasta que devuelva true.
#
# El limite total es de aproximadamente 45 segundos.
#
# Entre comprobaciones espera 0.2 segundos.
#
# Si la condicion se cumple, informa PASS.
#
# Si se agota el tiempo, informa FAIL.
#
# Se utiliza para esperar condiciones que pueden tardar,
# como una aplicacion de WAL o un bloqueo observable.
#
# 8. FUNCION guard()
# ----------------------------------------------------------------------
# Comprueba la identidad del directorio de datos.
#
# Utiliza:
#
# SHOW data_directory
#
# El valor devuelto debe coincidir con la ruta esperada
# para PostgreSQL A o PostgreSQL B.
#
# Esto ayuda a evitar operaciones sobre otra instancia.
#
# 9. FUNCION stop_cluster()
# ----------------------------------------------------------------------
# Recibe el nombre de una instancia.
#
# Si existe postmaster.pid, utiliza pg_ctl para detenerla.
#
# Opciones:
#
# - -D: identifica el directorio de datos.
# - -m fast: solicita apagado rapido.
# - -w: espera la terminacion.
# - -t 30: establece un limite de 30 segundos.
#
# Finalmente comprueba que postmaster.pid ya no exista.
#
# 10. FUNCION sync_replica()
# ----------------------------------------------------------------------
# Consulta pg_current_wal_lsn() en PostgreSQL A.
#
# Esta funcion obtiene la posicion WAL actual del principal.
#
# Posteriormente consulta en PostgreSQL B:
#
# pg_last_wal_replay_lsn()
#
# Espera hasta que la posicion reproducida por B
# alcance la posicion obtenida de A.
#
# No copia los datos manualmente.
#
# Comprueba el avance de la replicacion fisica existente.
#
# 11. CONSULTA total_sql
# ----------------------------------------------------------------------
# Calcula la suma de los importes de pedidos con:
#
# estado = PAGADO
# fecha = 2026-01-15
#
# Permite comprobar los totales:
#
# - 900 al comenzar.
# - 1100 despues de confirmar el pedido 101.
# - 1200 despues de insertar el pedido 105.
# - 1500 despues de insertar el pedido 106.
#
# 12. CONSULTA plan
# ----------------------------------------------------------------------
# Define la consulta utilizada para analizar rendimiento.
#
# Relaciona negocio.pedidos con negocio.clientes mediante JOIN.
#
# Filtra los pedidos pagados de la fecha didactica.
#
# Devuelve nombre, identificador, fecha e importe.
#
# Ordena los resultados por fecha e identificador.
#
# Esta consulta se utiliza junto con EXPLAIN
# y EXPLAIN ANALYZE para observar el plan de ejecucion.
#
# 13. RESULTADO ESPERADO
# ----------------------------------------------------------------------
# Los scripts pueden compartir configuracion y funciones
# sin repetir las mismas instrucciones en varios archivos.
#
# IMPORTANTE
# ----------------------------------------------------------------------
# source incorpora las variables y funciones al proceso Bash
# que lo ejecuta.
#
# Este archivo no inicia PostgreSQL ni modifica los datos
# por si mismo.
#
# ======================================================================

set -Eeuo pipefail
export LC_ALL=C
export PATH=/usr/bin:/usr/sbin:/bin:/sbin
unset PGOPTIONS PGSERVICE PGSERVICEFILE PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD
export PGCONNECT_TIMEOUT=5

R=/tmp/nobleprog-p7-integrado
E=$R/evidence
S=/tmp/p7-integrado-scripts
DB=nobleprog_integrado

sql() {
    psql -X -h 127.0.0.1 -p "$1" -U postgres -d "$DB" \
        -v ON_ERROR_STOP=1 -P pager=off "${@:2}"
}

q() {
    sql "$1" -Atq -c "$2"
}

check() {
    local result
    result=$(q "$2" "$3")
    if [ "$result" != "$4" ]; then
        echo "FAIL | $1 | esperado=$4 | obtenido=$result"
        return 1
    fi
    echo "PASS | $1"
}

poll() {
    local end=$((SECONDS+45)) result
    while [ "$SECONDS" -lt "$end" ]; do
        result=$(q "$2" "$3")
        if [ "$result" = t ]; then
            echo "PASS | $1"
            return 0
        fi
        sleep 0.2
    done
    echo "FAIL | Timeout: $1"
    return 1
}

guard() {
    local node=$2
    check 'Directorio de datos exclusivo' "$1" \
        'SHOW data_directory' "$R/$node"
}

stop_cluster() {
    if [ -f "$R/$1/postmaster.pid" ]; then
        pg_ctl -D "$R/$1" -m fast -w -t 30 stop
    fi
    test ! -f "$R/$1/postmaster.pid"
}

sync_replica() {
    local lsn
    lsn=$(q 5547 'SELECT pg_current_wal_lsn()')
    poll 'B aplico el WAL confirmado en A' 5548 \
        "SELECT pg_last_wal_replay_lsn()>='$lsn'::pg_lsn"
}

total_sql="SELECT sum(total)::integer FROM negocio.pedidos
WHERE estado='PAGADO' AND fecha=DATE '2026-01-15'"

plan="SELECT c.nombre,p.id,p.fecha,p.total
FROM negocio.pedidos p
JOIN negocio.clientes c ON c.id=p.cliente_id
WHERE p.estado='PAGADO' AND p.fecha=DATE '2026-01-15'
ORDER BY p.fecha,p.id"
