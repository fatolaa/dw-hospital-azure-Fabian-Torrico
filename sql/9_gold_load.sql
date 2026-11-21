-- ============================================================================
-- 9. CARGA GOLD: modelo estrella desde SILVER
-- ============================================================================
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
GO

DELETE FROM gold.fact_facturacion;
DELETE FROM gold.fact_admisiones;
DELETE FROM gold.dim_diagnostico;
DELETE FROM gold.dim_servicio_cargo;
DELETE FROM gold.dim_departamento;
DELETE FROM gold.dim_paciente;
DELETE FROM gold.dim_fecha;
GO

-- ---------------------------------------------------------------------------
-- 9.1 DIM_FECHA (todos los dias entre la fecha minima y maxima de silver)
-- ---------------------------------------------------------------------------
DECLARE @d0 DATE, @d1 DATE;
SELECT @d0 = MIN(x), @d1 = MAX(x)
FROM (SELECT admission_date AS x FROM silver.admissions
      UNION ALL SELECT discharge_date FROM silver.admissions
      UNION ALL SELECT payment_date FROM silver.billing) t
WHERE x IS NOT NULL;
SET @d0 = DATEFROMPARTS(YEAR(@d0), 1, 1);
SET @d1 = DATEFROMPARTS(YEAR(@d1), 12, 31);

WITH dias AS (
    SELECT @d0 AS f
    UNION ALL
    SELECT DATEADD(DAY, 1, f) FROM dias WHERE f < @d1
)
INSERT INTO gold.dim_fecha (fecha_key, fecha_completa, anio, trimestre, trimestre_nombre, mes, mes_nombre, mes_corto,
                            semana_anio, dia_mes, dia_semana, dia_nombre, es_fin_de_semana)
SELECT
    CAST(CONVERT(CHAR(8), f, 112) AS INT),
    f,
    YEAR(f),
    DATEPART(QUARTER, f),
    'T' + CAST(DATEPART(QUARTER, f) AS VARCHAR(1)),
    MONTH(f),
    CHOOSE(MONTH(f), 'Enero','Febrero','Marzo','Abril','Mayo','Junio','Julio','Agosto','Septiembre','Octubre','Noviembre','Diciembre'),
    CHOOSE(MONTH(f), 'Ene','Feb','Mar','Abr','May','Jun','Jul','Ago','Sep','Oct','Nov','Dic'),
    DATEPART(ISO_WEEK, f),
    DAY(f),
    (DATEDIFF(DAY, '19000101', f) % 7) + 1,          -- 1900-01-01 fue lunes: 1=Lunes ... 7=Domingo
    CHOOSE((DATEDIFF(DAY, '19000101', f) % 7) + 1, 'Lunes','Martes','Miercoles','Jueves','Viernes','Sabado','Domingo'),
    CASE WHEN (DATEDIFF(DAY, '19000101', f) % 7) + 1 >= 6 THEN 1 ELSE 0 END
FROM dias
OPTION (MAXRECURSION 0);
GO

-- ---------------------------------------------------------------------------
-- 9.2 DIM_PACIENTE
-- ---------------------------------------------------------------------------
INSERT INTO gold.dim_paciente (patient_id_bk, nombre_completo, genero, fecha_nacimiento, rango_etario,
                               correo_electronico, direccion, proveedor_seguro)
SELECT
    p.patient_id,
    p.full_name,
    CASE p.gender WHEN 'Male' THEN 'Masculino' WHEN 'Female' THEN 'Femenino' ELSE 'Otro' END,
    p.date_of_birth,
    CASE WHEN a.edad IS NULL THEN NULL
         WHEN a.edad <= 18 THEN '0-18'
         WHEN a.edad <= 35 THEN '19-35'
         WHEN a.edad <= 60 THEN '36-60'
         ELSE '60+' END,
    p.email,
    p.address,
    p.insurance_provider
FROM silver.patients p
CROSS APPLY (SELECT CASE WHEN p.date_of_birth IS NULL THEN NULL
                         ELSE DATEDIFF(YEAR, p.date_of_birth, GETDATE())
                              - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, p.date_of_birth, GETDATE()), p.date_of_birth) > CAST(GETDATE() AS DATE) THEN 1 ELSE 0 END
                    END AS edad) a;
GO

-- ---------------------------------------------------------------------------
-- 9.3 DIM_DEPARTAMENTO / DIM_SERVICIO_CARGO
-- ---------------------------------------------------------------------------
INSERT INTO gold.dim_departamento (nombre_departamento)
SELECT DISTINCT department FROM silver.admissions;

INSERT INTO gold.dim_servicio_cargo (tipo_cargo, estado_pago)
SELECT DISTINCT charge_type, payment_status FROM silver.billing;
GO

-- ---------------------------------------------------------------------------
-- 9.4 DIM_DIAGNOSTICO (una fila por diagnostico + fila 'Sin diagnostico')
-- ---------------------------------------------------------------------------
INSERT INTO gold.dim_diagnostico (diagnosis_id_bk, codigo_icd, descripcion_patologia, nivel_severidad)
VALUES (NULL, 'N/D', N'Admision sin diagnostico registrado', 'Unknown');

INSERT INTO gold.dim_diagnostico (diagnosis_id_bk, codigo_icd, descripcion_patologia, nivel_severidad)
SELECT diagnosis_id, icd_code, diagnosis_description, severity
FROM silver.diagnoses;
GO

-- ---------------------------------------------------------------------------
-- 9.5 FACT_ADMISIONES (grano: una fila por admision, con su diagnostico principal)
-- ---------------------------------------------------------------------------
INSERT INTO gold.fact_admisiones (admission_id_bk, paciente_key, departamento_key, diagnostico_key,
                                  fecha_ingreso_key, fecha_alta_key, medico_id, dias_estancia, conteo_admisiones)
SELECT
    a.admission_id,
    dp.paciente_key,
    dd.departamento_key,
    COALESCE(dg.diagnostico_key, nd.diagnostico_key),
    CAST(CONVERT(CHAR(8), a.admission_date, 112) AS INT),
    CASE WHEN a.discharge_date IS NULL THEN NULL ELSE CAST(CONVERT(CHAR(8), a.discharge_date, 112) AS INT) END,
    a.attending_doctor_id,
    CASE WHEN a.discharge_date IS NULL THEN NULL ELSE DATEDIFF(DAY, a.admission_date, a.discharge_date) END,
    1
FROM silver.admissions a
JOIN gold.dim_paciente dp ON dp.patient_id_bk = a.patient_id
JOIN gold.dim_departamento dd ON dd.nombre_departamento = a.department
LEFT JOIN (SELECT admission_id, MIN(diagnosis_id) AS diagnosis_id FROM silver.diagnoses GROUP BY admission_id) pd
       ON pd.admission_id = a.admission_id
LEFT JOIN gold.dim_diagnostico dg ON dg.diagnosis_id_bk = pd.diagnosis_id
CROSS JOIN (SELECT diagnostico_key FROM gold.dim_diagnostico WHERE diagnosis_id_bk IS NULL) nd;
GO

-- ---------------------------------------------------------------------------
-- 9.6 FACT_FACTURACION
-- ---------------------------------------------------------------------------
INSERT INTO gold.fact_facturacion (billing_id_bk, admission_id_bk, paciente_key, departamento_key, servicio_cargo_key,
                                   fecha_pago_key, monto_facturado, conteo_transacciones)
SELECT
    b.billing_id,
    b.admission_id,
    dp.paciente_key,
    dd.departamento_key,
    sc.servicio_cargo_key,
    CASE WHEN b.payment_date IS NULL THEN NULL ELSE CAST(CONVERT(CHAR(8), b.payment_date, 112) AS INT) END,
    b.amount,
    1
FROM silver.billing b
JOIN silver.admissions a ON a.admission_id = b.admission_id
JOIN gold.dim_paciente dp ON dp.patient_id_bk = a.patient_id
JOIN gold.dim_departamento dd ON dd.nombre_departamento = a.department
JOIN gold.dim_servicio_cargo sc ON sc.tipo_cargo = b.charge_type AND sc.estado_pago = b.payment_status;
GO

PRINT 'Gold cargada.';
GO
