SELECT c.nombre,
       count(*) AS pedidos_pagados,
       sum(p.total) AS total
FROM negocio.clientes c
JOIN negocio.pedidos p ON p.cliente_id=c.id
WHERE p.estado='PAGADO' AND p.fecha=DATE '2026-01-15'
GROUP BY c.id,c.nombre
ORDER BY c.nombre;
