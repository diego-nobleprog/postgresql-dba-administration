SELECT c.nombre,p.id,p.fecha,p.total
FROM negocio.pedidos p
JOIN negocio.clientes c ON c.id=p.cliente_id
WHERE p.estado='PAGADO' AND p.fecha=DATE '2026-01-15'
ORDER BY p.fecha,p.id;
