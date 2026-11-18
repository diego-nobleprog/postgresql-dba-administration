#!/bin/bash
# ======================================================================
# ARCHIVO: 02-simulate-primary-server-failure.sh
# ======================================================================
#
# OBJETIVO
# ----------------------------------------------------------------------
# Simular la indisponibilidad de PostgreSQL A durante el escenario
# 07.03, conservando PostgreSQL B como standby disponible.
#
# Este script representa el momento en que el servidor principal
# deja de aceptar conexiones y debe iniciarse el procedimiento
# de promocion de la replica.
#
# 1. CARGA DE CONFIGURACION COMPARTIDA
# ----------------------------------------------------------------------
# source incorpora las funciones de:
#
# aux-shared-environment-functions.sh
#
# Estas funciones permiten realizar consultas, comprobar
# resultados, detener instancias y verificar replicacion.
#
# 2. IDENTIFICACION DE LAS INSTANCIAS
# ----------------------------------------------------------------------
# guard 5547 A comprueba que el puerto 5547 corresponde
# al directorio de datos de PostgreSQL A.
#
# guard 5548 B realiza la misma comprobacion para B.
#
# Esto evita ejecutar las operaciones sobre una instancia
# diferente de la prevista para el laboratorio.
#
# 3. COMPROBACION DE ROLES
# ----------------------------------------------------------------------
# Se consulta pg_is_in_recovery() en ambas instancias.
#
# Resultado esperado:
#
# - A: false. Esta funcionando como PRIMARY.
# - B: true. Continua funcionando como STANDBY.
#
# La operacion solamente debe continuar cuando
# la arquitectura conserva los roles esperados.
#
# 4. COMPROBACION DE LOS DATOS
# ----------------------------------------------------------------------
# Se ejecuta la consulta compartida total_sql.
#
# Esta consulta suma los importes de los pedidos PAGADOS
# correspondientes a la fecha 2026-01-15.
#
# Antes de simular la falla, el total en A debe ser 1200.
#
# Ese valor demuestra que el escenario 07.02 termino
# con los cambios de negocio previstos.
#
# 5. SINCRONIZACION ANTES DE LA FALLA
# ----------------------------------------------------------------------
# sync_replica obtiene una posicion WAL del servidor A.
#
# Posteriormente espera hasta que PostgreSQL B haya
# reproducido los cambios hasta esa posicion.
#
# Una vez completada la espera, se comprueba que
# el total de pedidos pagados en B tambien sea 1200.
#
# Esto establece una referencia conocida antes de detener A.
#
# 6. DETENCION DEL SERVIDOR PRINCIPAL
# ----------------------------------------------------------------------
# stop_cluster A solicita una detencion controlada de A.
#
# La funcion utiliza pg_ctl con modalidad fast.
#
# En esta modalidad PostgreSQL termina las conexiones activas
# y realiza el apagado correspondiente.
#
# El script no detiene B ni elimina sus archivos.
#
# 7. VERIFICACION DE INDISPONIBILIDAD
# ----------------------------------------------------------------------
# pg_isready intenta comprobar la disponibilidad de A
# utilizando el puerto 5547.
#
# Si A todavia acepta conexiones, el script falla.
#
# Si pg_isready devuelve el codigo 2, se confirma que
# no existe respuesta del servidor en ese puerto.
#
# Otros codigos de error no se aceptan como comprobacion
# suficiente de la indisponibilidad esperada.
#
# 8. RESULTADO ESPERADO
# ----------------------------------------------------------------------
# PostgreSQL A permanece detenido.
#
# PostgreSQL B conserva:
#
# - Los datos replicados.
# - El indice creado durante el escenario 07.01.
# - Su estado actual de standby.
#
# El siguiente paso del ejercicio consiste en promover B
# mediante pg_promote().
#
# IMPORTANTE
# ----------------------------------------------------------------------
# Este script no ejecuta la promocion.
#
# La promocion se realiza posteriormente durante el
# escenario 07.03.
#
# ARCHIVOS RELACIONADOS
# ----------------------------------------------------------------------
# aux-shared-environment-functions.sh
# aux-verify-standby-synchronization.sh
#
# ======================================================================

source /tmp/p7-integrado-scripts/aux-shared-environment-functions.sh

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
