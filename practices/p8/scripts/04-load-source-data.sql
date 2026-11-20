-- Ejecutar la carga con el propietario de las tablas.
SET ROLE p8_owner;

-- Crear los clientes originales.
INSERT INTO comercial.clientes (cliente_id,nombre,ciudad) VALUES (101,'Ana','CDMX'),(102,'Luis','Puebla');

-- Crear los tres productos comerciales.
INSERT INTO comercial.productos (producto_id,nombre,precio) VALUES (1,'Teclado',500),(2,'Mouse',200),(3,'Monitor',1200);

-- Crear los dos pedidos con identificadores historicos.
INSERT INTO comercial.pedidos (pedido_id,cliente_id,total,estado) VALUES (5001,101,700,'PENDIENTE'),(5002,102,1200,'PAGADO');

-- Crear el detalle de los productos comprados.
INSERT INTO comercial.detalles (pedido_id,producto_id,cantidad,subtotal) VALUES (5001,1,1,500),(5001,2,1,200),(5002,3,1,1200);

-- Crear el pago historico del pedido de Luis.
INSERT INTO comercial.pagos (pago_id,pedido_id,monto) VALUES (9001,5002,1200);

-- Actualizar la vista materializada.
REFRESH MATERIALIZED VIEW reportes.mv_ventas_pagadas;

-- Regresar al usuario administrador.
RESET ROLE;

-- Mostrar los pedidos cargados.
TABLE comercial.pedidos;

-- Mostrar las ventas pagadas por cliente.
TABLE reportes.mv_ventas_pagadas;
