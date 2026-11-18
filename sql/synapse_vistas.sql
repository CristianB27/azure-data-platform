-- =====================================================================
-- Proyecto 09 - Synapse Serverless SQL (workspace syn-p09utb-461l)
-- Script ejecutado manualmente en Synapse Studio (pool "Integrado").
-- Ejecutar cada bloque POR SEPARADO, en el orden indicado.
-- Data Lake: stp09utbdl461l
-- =====================================================================

-- ---------------------------------------------------------------------
-- BLOQUE A  (base de datos: master)
-- ---------------------------------------------------------------------
CREATE DATABASE p09utb;

-- ---------------------------------------------------------------------
-- BLOQUE B  (base de datos: p09utb)
-- La clave de la llave maestra es solo un requisito tecnico; no se vuelve
-- a usar. Reemplazar el marcador por cualquier clave.
-- ---------------------------------------------------------------------
CREATE MASTER KEY ENCRYPTION BY PASSWORD = '<ClaveCualquiera1!>';

CREATE DATABASE SCOPED CREDENTIAL cred_msi WITH IDENTITY = 'Managed Identity';

CREATE EXTERNAL DATA SOURCE ds_lake
WITH (LOCATION = 'https://stp09utbdl461l.dfs.core.windows.net', CREDENTIAL = cred_msi);

-- ---------------------------------------------------------------------
-- BLOQUE C  (base de datos: p09utb) - Vistas externas sobre Parquet
-- En Synapse Studio no se usa GO: ejecutar cada CREATE VIEW por separado.
-- ---------------------------------------------------------------------
CREATE VIEW dbo.vw_silver_telemetria AS
SELECT * FROM OPENROWSET(
    BULK 'silver/telemetria/*.parquet',
    DATA_SOURCE = 'ds_lake', FORMAT = 'PARQUET') AS r;

CREATE VIEW dbo.vw_gold_telemetria_diaria AS
SELECT * FROM OPENROWSET(
    BULK 'gold/telemetria_diaria/*.parquet',
    DATA_SOURCE = 'ds_lake', FORMAT = 'PARQUET') AS r;

-- Fase 11: Gold de la ruta streaming (mismo esquema que el Gold batch)
CREATE VIEW dbo.vw_gold_streaming_diaria AS
SELECT * FROM OPENROWSET(
    BULK 'gold/telemetria_streaming_diaria/*.parquet',
    DATA_SOURCE = 'ds_lake', FORMAT = 'PARQUET') AS r;

-- Convergencia batch + streaming (columna "fuente")
CREATE VIEW dbo.vw_gold_unificada AS
SELECT 'batch' AS fuente, device_id, fecha, lecturas, temp_promedio, temp_maxima,
       humedad_promedio, presion_promedio
FROM dbo.vw_gold_telemetria_diaria
UNION ALL
SELECT 'streaming' AS fuente, device_id, fecha, lecturas, temp_promedio, temp_maxima,
       humedad_promedio, presion_promedio
FROM dbo.vw_gold_streaming_diaria;

-- ---------------------------------------------------------------------
-- BLOQUE D  Verificaciones
-- ---------------------------------------------------------------------
SELECT TOP 10 * FROM dbo.vw_gold_telemetria_diaria;

SELECT COUNT(*) AS filas FROM dbo.vw_silver_telemetria;

SELECT fuente, COUNT(*) AS filas, SUM(lecturas) AS lecturas,
       MIN(fecha) AS desde, MAX(fecha) AS hasta
FROM dbo.vw_gold_unificada
GROUP BY fuente;

-- ---------------------------------------------------------------------
-- BLOQUE E  Tres consultas analiticas (PDF 4.4)
-- ---------------------------------------------------------------------
-- 1. Tendencia temporal: promedio y maximo por dia
SELECT fecha,
       ROUND(AVG(temp_promedio), 2) AS temp_media,
       MAX(temp_maxima)             AS temp_max_dia,
       SUM(lecturas)                AS lecturas
FROM dbo.vw_gold_telemetria_diaria
GROUP BY fecha
ORDER BY fecha;

-- 2. Top-N: los 3 sensores con la temperatura mas alta
SELECT TOP 3 device_id,
       MAX(temp_maxima)             AS temp_max,
       ROUND(AVG(temp_promedio), 2) AS temp_media
FROM dbo.vw_gold_telemetria_diaria
GROUP BY device_id
ORDER BY temp_max DESC;

-- 3. Agregacion por categoria (sensor)
-- Nota: AVG de promedios no pondera por numero de lecturas (aproximado).
SELECT device_id,
       SUM(lecturas)                   AS lecturas,
       ROUND(AVG(humedad_promedio), 2) AS humedad_media,
       ROUND(AVG(presion_promedio), 2) AS presion_media
FROM dbo.vw_gold_telemetria_diaria
GROUP BY device_id
ORDER BY device_id;

-- ---------------------------------------------------------------------
-- PRUEBA DE PERMISOS POR CAPA (Fase 8): Synapse NO tiene rol sobre bronze.
-- Esta consulta debe FALLAR por permisos (evidencia de la restriccion).
-- ---------------------------------------------------------------------
-- SELECT TOP 5 * FROM OPENROWSET(
--     BULK 'bronze/batch/*.parquet',
--     DATA_SOURCE = 'ds_lake', FORMAT = 'PARQUET') AS r;
