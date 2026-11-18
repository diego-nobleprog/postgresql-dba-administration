/*
======================================================================
ARCHIVO: aux-create-tables-and-load-sample-data.sql
======================================================================

OBJETIVO
----------------------------------------------------------------------
Crear las estructuras y los registros utilizados durante
los tres escenarios integrados del laboratorio.

Los datos se mantienen sencillos para facilitar
la interpretacion de las operaciones de negocio.

1. EXTENSION DE ESTADISTICAS
----------------------------------------------------------------------
CREATE EXTENSION pg_stat_statements habilita la extension
en la base de datos.

Permite consultar estadisticas acumuladas de sentencias SQL.

Su biblioteca debe encontrarse previamente configurada
en shared_preload_libraries.

2. CREACION DEL ESQUEMA
----------------------------------------------------------------------
CREATE SCHEMA negocio crea un espacio de nombres
para separar las tablas de esta practica.

Las tablas se identificaran mediante:

negocio.clientes
negocio.pedidos

3. TABLA CLIENTES
----------------------------------------------------------------------
Se crea negocio.clientes con dos columnas:

id:
Identificador numerico y llave primaria.

nombre:
Nombre del cliente. No permite valores NULL.

4. TABLA PEDIDOS
----------------------------------------------------------------------
Se crea negocio.pedidos con cinco columnas:

id:
Identificador numerico y llave primaria.

cliente_id:
Identificador del cliente propietario del pedido.

La llave foranea exige que exista el cliente asociado.

fecha:
Fecha del pedido. No admite NULL.

estado:
Solo admite PENDIENTE o PAGADO mediante CHECK.

total:
Importe numeric(12,2), mayor o igual que cero.

5. CARGA DE CLIENTES
----------------------------------------------------------------------
Se insertan tres clientes:

1 - Ana
2 - Luis
3 - Maria

Estos clientes se utilizan en todos los ejercicios.

6. CARGA DE PEDIDOS RECIENTES
----------------------------------------------------------------------
Se insertan cuatro pedidos con fecha 2026-01-15.

Pedido 101:
Ana, PENDIENTE, importe 200.

Pedido 102:
Luis, PAGADO, importe 500.

Pedido 103:
Ana, PAGADO, importe 150.

Pedido 104:
Maria, PAGADO, importe 250.

Resultado inicial:

4 pedidos recientes.
3 pedidos pagados.
Importe pagado: 900.

7. GENERACION DE DATOS HISTORICOS
----------------------------------------------------------------------
generate_series(1,50000) genera 50000 valores.

Cada valor permite construir un pedido historico.

Los identificadores comienzan en 1001.

cliente_id distribuye los pedidos entre los tres clientes
utilizando una operacion de modulo.

La fecha se calcula a partir de 2025-01-01,
distribuyendo los registros en un intervalo de 300 dias.

Todos los pedidos historicos tienen:

estado = PAGADO
total = 10

Estos registros proporcionan volumen para analizar
planes de ejecucion y filtrado de consultas.

No pertenecen a la fecha didactica 2026-01-15.

8. ACTUALIZACION DE ESTADISTICAS
----------------------------------------------------------------------
ANALYZE negocio.clientes recopila estadisticas de clientes.

ANALYZE negocio.pedidos recopila estadisticas de pedidos.

PostgreSQL utiliza estas estadisticas para estimar
cantidades de filas y costos de ejecucion.

9. RESULTADO ESPERADO
----------------------------------------------------------------------
Clientes: 3.

Pedidos: 50004.

Pedidos recientes: 4.

Pedidos recientes pagados: 3.

Importe pagado reciente: 900.

IMPORTANTE
----------------------------------------------------------------------
Este archivo prepara los datos originales.

No crea el indice experimental utilizado
durante el escenario 07.01.

Ese indice se crea posteriormente para poder comparar
el rendimienta la fecha didactica del laboratorio.

Los 50000 pedidos historicos no cumplen este filtro.

6. ORDENAMIENTO
----------------------------------------------------------------------
ORDER BY p.fecha, p.id ordena los registros.

Primero utiliza la fecha y despues el identificador.

Como todos los registros seleccionados comparten
la misma fecha, el identificador determina su orden.

7. RESULTADO INICIAL ESPERADO
----------------------------------------------------------------------
Luis  - Pedido 102 - 500.
Ana   - Pedido 103 - 150.
Maria - Pedido 104 - 250.

Total de registros devueltos: 3.

El pedido 101 no aparece porque esta PENDIENTE.

8. TRANSFORMACION DURANTE EL LABORATORIO
----------------------------------------------------------------------
Cuando el pedido 101 cambia a PAGADO,
la consulta pasa a devolver cuatro registros.

Despues de insertar el pedido 105,
devuelve cinco registros.

Finalmente, despues de insertar el pedido 106,
devuelve seis registros.

9. RELACION CON PERFORMANCE TUNING
----------------------------------------------------------------------
La consulta permite observar:

- EXPLAIN.
- EXPLAIN ANALYZE.
- BUFFERS.
- JOIN.
- Filtros por estado y fecha.
- ORDER BY.
- Efecto del indice compuesto.
- Estadisticas de pg_stat_statements.

IMPORTANTE
----------------------------------------------------------------------
Esta consulta solamente lee informacion.

No modifica registros ni crea indices.

======================================================================
*/

CREATE EXTENSION pg_stat_statements;
CREATE SCHEMA negocio;

CREATE TABLE negocio.clientes(
    id integer PRIMARY KEY,
    nombre text NOT NULL
);

CREATE TABLE negocio.pedidos(
    id integer PRIMARY KEY,
    cliente_id integer NOT NULL REFERENCES negocio.clientes(id),
    fecha date NOT NULL,
    estado text NOT NULL CHECK(estado IN ('PENDIENTE','PAGADO')),
    total numeric(12,2) NOT NULL CHECK(total>=0)
);

INSERT INTO negocio.clientes VALUES
(1,'Ana'),(2,'Luis'),(3,'Maria');

INSERT INTO negocio.pedidos VALUES
(101,1,'2026-01-15','PENDIENTE',200),
(102,2,'2026-01-15','PAGADO',500),
(103,1,'2026-01-15','PAGADO',150),
(104,3,'2026-01-15','PAGADO',250);

INSERT INTO negocio.pedidos
SELECT 1000+g,
       1+(g%3),
       DATE '2025-01-01'+(g%300),
       'PAGADO',
       10
FROM generate_series(1,50000) g;

ANALYZE negocio.clientes;
ANALYZE negocio.pedidos;
