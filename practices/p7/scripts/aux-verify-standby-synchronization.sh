#!/bin/bash
# ======================================================================
# ARCHIVO: aux-verify-standby-synchronization.sh
# ======================================================================
#
# OBJETIVO
# ----------------------------------------------------------------------
# Comprobar que PostgreSQL B haya reproducido los cambios
# registrados en WAL por PostgreSQL A.
#
# Este archivo verifica el avance de una replicacion
# fisica que ya se encuentra funcionando.
#
# No copia registros manualmente.
#
# 1. CARGA DE CONFIGURACION
# ----------------------------------------------------------------------
# source incorpora las variables y funciones del archivo:
#
# aux-shared-environment-functions.sh
#
# Se utilizan tres funciones:
#
# guard:
# Comprueba la identidad de una instancia PostgreSQL.
#
# check:
# Ejecuta una consulta y compara su resultado con
# un valor esperado.
#
# sync_replica:
# Espera hasta que B haya reproducido una posicion WAL de A.
#
# 2. IDENTIFICACION DE POSTGRESQL A
# ----------------------------------------------------------------------
# guard 5547 A conecta al servidor del puerto 5547.
#
# Ejecuta:
#
# SHOW data_directory
#
# El resultado debe coincidir con el directorio R/A.
#
# Esto confirma que se esta consultando la instancia
# principal prevista para el laboratorio.
#
# 3. IDENTIFICACION DE POSTGRESQL B
# ----------------------------------------------------------------------
# guard 5548 B realiza una comprobacion equivalente.
#
# Se conecta al puerto 5548.
#
# SHOW data_directory debe identificar R/B.
#
# Esto confirma que la conexion corresponde a B.
#
# 4. VERIFICACION DEL ROL STANDBY
# ----------------------------------------------------------------------
# Se ejecuta:
#
# SELECT pg_is_in_recovery()
#
# La consulta se realiza sobre PostgreSQL B.
#
# Resultado esperado:
#
# true
#
# Esto significa que B continua funcionando en modo
# de recuperacion y todavia no ha sido promovido.
#
# Si devuelve false, el archivo termina con error.
#
# 5. OBTENCION DE LA POSICION WAL
# ----------------------------------------------------------------------
# sync_replica consulta en PostgreSQL A:
#
# SELECT pg_current_wal_lsn()
#
# Esta funcion obtiene una posicion actual del WAL.
#
# LSN significa Log Sequence Number.
#
# Representa una posicion dentro del flujo WAL.
#
# El valor se utiliza como referencia para comprobar
# el avance de la replicacion.
#
# 6. COMPROBACION DEL WAL REPRODUCIDO
# ----------------------------------------------------------------------
# En PostgreSQL B se consulta:
#
# pg_last_wal_replay_lsn()
#
# Esta funcion devuelve la ultima posicion WAL
# reproducida durante la recuperacion.
#
# La comprobacion compara ambos valores.
#
# B debe haber reproducido una posicion mayor o igual
# a la obtenida previamente en A.
#
# 7. ESPERA DE SINCRONIZACION
# ----------------------------------------------------------------------
# La funcion sync_replica utiliza poll.
#
# poll repite la consulta hasta que la condicion
# de sincronizacion devuelve true.
#
# El limite de espera es aproximadamente 45 segundos.
#
# Entre intentos se realiza una pausa de 0.2 segundos.
#
# Si B alcanza el LSN esperado, se informa PASS.
#
# Si se agota el tiempo, se informa FAIL.
#
# 8. INTERPRETACION
# ----------------------------------------------------------------------
# Supongamos que A registra una posicion WAL:
#
# 0/2000100
#
# Si B solamente ha reproducido:
#
# 0/2000000
#
# Todavia debe aplicar mas informacion.
#
# Cuando B alcanza:
#
# 0/2000100
#
# Se cumple la condicion de sincronizacion.
#
# Estas posiciones son ejemplos ilustrativos.
#
# 9. RESULTADO ESPERADO
# ----------------------------------------------------------------------
# PostgreSQL A conserva su identidad.
#
# PostgreSQL B conserva su identidad y rol standby.
#
# B ha reproducido WAL al menos hasta la posicion
# que se obtuvo de A para la comprobacion.
#
# IMPORTANTE
# ----------------------------------------------------------------------
# Este resultado no significa que B dejara de recibir WAL.
#
# La replicacion continua funcionando.
#
# Tampoco garantiza que B permanecera actualizado
# para escrituras posteriores a la posicion comprobada.
#
# ARCHIVOS RELACIONADOS
# ----------------------------------------------------------------------
# aux-shared-environment-functions.sh
# aux-configure-primary-and-standby.sh
#
# ======================================================================

source /tmp/p7-integrado-scripts/aux-shared-environment-functions.sh

guard 5547 A
guard 5548 B
check 'B todavia standby' 5548 'SELECT pg_is_in_recovery()' t
sync_replica
