/*
======================================================================
ARCHIVO: aux-query-recent-paid-orders.sql
======================================================================

OBJETIVO
----------------------------------------------------------------------
Consultar individualmente los pedidos pagados
de la fecha utilizada durante el laboratorio.

La consulta permite analizar JOIN, filtros,
ordenamiento, planes de ejecucion y rendimiento.

1. COLUMNAS CONSULTADAS
----------------------------------------------------------------------
SELECT c.nombre, p.id, p.fecha, p.total

c.nombre:

Obtiene el nombre del cliente.

p.id:

Obtiene el identificador del pedido.

p.fecha:

Obtiene la fecha del pedido.

p.total:

Obtiene el importe del pedido.

2. TABLA PRINCIPAL
----------------------------------------------------------------------
FROM negocio.pedidos p

Identifica la tabla donde se almacenan los pedidos.

El alias p permite referirse a sus columnas
sin escribir repetidamente el nombre completo.

3. RELACION ENTRE TABLAS
----------------------------------------------------------------------
JOIN negocio.clientes c

Incorpora la tabla de clientes.

El alias c identifica esta segunda tabla.

La condicion utilizada es:

c.id = p.cliente_id

Cada pedido se relaciona con el cliente propietario.

Se utiliza INNER JOIN.

Por tanto, solamente se devuelven registros
con una relacion coincidente entre ambas tablas.

4. FILTRO POR ESTADO
----------------------------------------------------------------------
WHERE p.estado='PAGADO'

Selecciona solamente los pedidos cuyo estado
sea exactamente PAGADO.

Los pedidos con estado PENDIENTE quedan excluidos.

5. FILTRO POR FECHA
----------------------------------------------------------------------
p.fecha=DATE '2026-01-15'

Selecciona pedidos de la fecha didactica.

DATE indica que el valor debe interpretarse
como un dato de tipo fecha.

Los 50000 registros historicos utilizan otras fechas
y no deben aparecer en el resultado.

6. COMBINACION DE CONDICIONES
----------------------------------------------------------------------
Se utiliza AND para exigir simultaneamente:

estado = PAGADO

fecha = 2026-01-15

Un pedido debe cumplir ambas condiciones
para aparecer en el resultado.

7. ORDENAMIENTO
----------------------------------------------------------------------
ORDER BY p.fecha, p.id

Ordena primero por fecha y despues por identificador.

Como todos los pedidos seleccionados tienen
la misma fecha, el identificador determina el orden.

8. RESULTADO INICIAL
----------------------------------------------------------------------
CLIENTE  PEDIDO  IMPORTE

Luis     102     500
Ana      103     150
Maria    104     250

Cantidad de filas: 3.

El pedido 101 no aparece porque esta PENDIENTE.

9. TRANSFORMACION DEL RESULTADO
----------------------------------------------------------------------
ESCENARIO 07.01

La consulta devuelve tres pedidos pagados.

El indice modifica las posibilidades de acceso
a los datos, pero no altera los registros.

ESCENARIO 07.02

El pedido 101 cambia a PAGADO.

La consulta devuelve cuatro pedidos despues
de que el cambio ha sido confirmado.

Posteriormente se inserta el pedido 105.

La consulta pasa a devolver cinco pedidos.

ESCENARIO 07.03

PostgreSQL B se convierte en PRIMARY.

Se inserta el pedido 106.

La consulta pasa a devolver seis pedidos.

10. RELACION CON PERFORMANCE TUNING
----------------------------------------------------------------------
Esta consulta permite analizar:

EXPLAIN:

Muestra el plan estimado sin ejecutar la consulta.

EXPLAIN ANALYZE:

Ejecuta la consulta y muestra mediciones reales.

BUFFERS:

Permite observar accesos a buffers de PostgreSQL.

JOIN:

Relaciona pedidos con clientes.

WHERE:

Filtra los registros de interes.

ORDER BY:

Ordena los resultados.

INDICE COMPUESTO:

Permite evaluar un acceso mediante las columnas
estado y fecha.

11. RESULTADO ESPERADO
----------------------------------------------------------------------
Una consulta de solo lectura.

Filas correspondientes exclusivamente a pedidos
pagados de la fecha indicada.

Resultados consistentes con las modificaciones
confirmadas durante los ejercicios.

IMPORTANTE
----------------------------------------------------------------------
Este archivo no modifica datos.

No crea ni elimina indices.

No cambia la configuracion de PostgreSQL.

======================================================================
*/

SELECT c.nombre,p.id,p.fecha,p.total
FROM negocio.pedidos p
JOIN negocio.clientes c ON c.id=p.cliente_id
WHERE p.estado='PAGADO' AND p.fecha=DATE '2026-01-15'
ORDER BY p.fecha,p.id;
