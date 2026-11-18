/*
======================================================================
ARCHIVO: aux-report-paid-orders-by-customer.sql
======================================================================

OBJETIVO
----------------------------------------------------------------------
Generar un reporte agregado de pedidos pagados por cliente.

El reporte permite verificar que las operaciones realizadas
durante los tres escenarios produzcan los importes esperados.

1. COLUMNAS DEL REPORTE
----------------------------------------------------------------------
c.nombre:
Nombre del cliente.

count(*):
Cantidad de pedidos pagados del cliente.

El resultado utiliza el alias pedidos_pagados.

sum(p.total):
Suma de los importes de esos pedidos.

El resultado utiliza el alias total.

2. RELACION ENTRE TABLAS
----------------------------------------------------------------------
FROM negocio.clientes c identifica la tabla de clientes.

JOIN negocio.pedidos p incorpora sus pedidos.

La relacion se realiza mediante:

p.cliente_id = c.id

3. FILTRO POR ESTADO
----------------------------------------------------------------------
Solamente se consideran pedidos PAGADOS.

Los pedidos PENDIENTES no contribuyen
a las cantidades ni a los importes.

4. FILTRO POR FECHA
----------------------------------------------------------------------
Se utiliza la fecha 2026-01-15.

Los pedidos historicos quedan excluidos del reporte.

5. AGRUPACION
----------------------------------------------------------------------
GROUP BY c.id, c.nombre organiza los registros
en grupos correspondientes a cada cliente.

COUNT calcula la cantidad de pedidos de cada grupo.

SUM calcula el importe acumulado de cada grupo.

6. ORDENAMIENTO
----------------------------------------------------------------------
ORDER BY c.nombre presenta los clientes
ordenados alfabeticamente por nombre.

7. RESULTADO INICIAL
----------------------------------------------------------------------
Ana:   1 pedido, 150.
Luis:  1 pedido, 500.
Maria: 1 pedido, 250.

Total general: 900.

8. CAMBIO DEL PEDIDO 101
----------------------------------------------------------------------
Cuando el pedido 101 pasa a PAGADO:

Ana tiene dos pedidos pagados.

El total de Ana pasa de 150 a 350.

El total general pasa de 900 a 1100.

9. INSERCION DEL PEDIDO 105
----------------------------------------------------------------------
Se agrega un pedido pagado de Luis por 100.

Luis pasa de 500 a 600.

El total general pasa de 1100 a 1200.

10. INSERCION DEL PEDIDO 106
----------------------------------------------------------------------
Se agrega un pedido pagado de Ana por 300.

Ana pasa de 350 a 650.

El total general pasa de 1200 a 1500.

11. RELACION CON EL LABORATORIO
----------------------------------------------------------------------
Este reporte permite observar:

- INNER JOIN.
- GROUP BY.
- COUNT.
- SUM.
- ORDER BY.
- Transformacion de los datos.
- Integridad de resultados entre instancias.
- Continuidad del servicio despues de la promocion.

IMPORTANTE
----------------------------------------------------------------------
La consulta es de solo lectura.

No modifica los pedidos ni calcula un total general
como fila independiente; los importes pueden sumarse
a partir de las filas agrupadas.

======================================================================
*/

SELECT c.nombre,
       count(*) AS pedidos_pagados,
       sum(p.total) AS total
FROM negocio.clientes c
JOIN negocio.pedidos p ON p.cliente_id=c.id
WHERE p.estado='PAGADO' AND p.fecha=DATE '2026-01-15'
GROUP BY c.id,c.nombre
ORDER BY c.nombre;
