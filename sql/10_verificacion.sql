-- Verificacion manual (Query editor de Azure o sqlcmd). No lo ejecuta Terraform.
SELECT 'bronze.patients' AS tabla, COUNT(*) AS filas FROM bronze.patients
UNION ALL SELECT 'bronze.admissions', COUNT(*) FROM bronze.admissions
UNION ALL SELECT 'bronze.diagnoses',  COUNT(*) FROM bronze.diagnoses
UNION ALL SELECT 'bronze.billing',    COUNT(*) FROM bronze.billing
UNION ALL SELECT 'silver.patients',   COUNT(*) FROM silver.patients
UNION ALL SELECT 'silver.admissions', COUNT(*) FROM silver.admissions
UNION ALL SELECT 'silver.diagnoses',  COUNT(*) FROM silver.diagnoses
UNION ALL SELECT 'silver.billing',    COUNT(*) FROM silver.billing
UNION ALL SELECT 'silver.cuarentena', COUNT(*) FROM silver.cuarentena
UNION ALL SELECT 'gold.dim_fecha',    COUNT(*) FROM gold.dim_fecha
UNION ALL SELECT 'gold.dim_paciente', COUNT(*) FROM gold.dim_paciente
UNION ALL SELECT 'gold.dim_departamento', COUNT(*) FROM gold.dim_departamento
UNION ALL SELECT 'gold.dim_diagnostico',  COUNT(*) FROM gold.dim_diagnostico
UNION ALL SELECT 'gold.dim_servicio_cargo', COUNT(*) FROM gold.dim_servicio_cargo
UNION ALL SELECT 'gold.fact_admisiones',  COUNT(*) FROM gold.fact_admisiones
UNION ALL SELECT 'gold.fact_facturacion', COUNT(*) FROM gold.fact_facturacion;

SELECT tabla_origen, motivo, COUNT(*) AS filas FROM silver.cuarentena GROUP BY tabla_origen, motivo ORDER BY tabla_origen, filas DESC;

SELECT TOP 10 * FROM silver.patients;
SELECT TOP 10 * FROM gold.fact_admisiones;

SELECT d.nombre_departamento, COUNT(*) AS admisiones, AVG(f.dias_estancia * 1.0) AS estancia_promedio
FROM gold.fact_admisiones f JOIN gold.dim_departamento d ON d.departamento_key = f.departamento_key
GROUP BY d.nombre_departamento ORDER BY admisiones DESC;
