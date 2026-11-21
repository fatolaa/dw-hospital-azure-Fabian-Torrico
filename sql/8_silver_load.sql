-- ============================================================================
-- 8. CARGA SILVER: limpieza, estandarizacion y tipado desde BRONZE
-- Las filas que no cumplen las reglas de calidad van a silver.cuarentena.
-- ============================================================================
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
GO

-- ---------------------------------------------------------------------------
-- Funciones auxiliares
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS silver.fn_parse_date;
GO
CREATE FUNCTION silver.fn_parse_date (@s NVARCHAR(200), @pivot INT)
RETURNS DATE
AS
BEGIN
    -- Formatos de bronze: yyyy-mm-dd | mm/dd/yyyy | mm-dd-yy | dd-Mon-yyyy | Month dd, yyyy
    SET @s = LTRIM(RTRIM(@s));
    IF @s IS NULL OR @s = N'' RETURN NULL;
    DECLARE @iso VARCHAR(10) = NULL, @pos INT, @m INT, @yy INT, @mname VARCHAR(3);
    DECLARE @months VARCHAR(40) = 'JANFEBMARAPRMAYJUNJULAUGSEPOCTNOVDEC';

    IF @s LIKE '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
        SET @iso = @s;
    ELSE IF @s LIKE '[0-9][0-9]/[0-9][0-9]/[0-9][0-9][0-9][0-9]'
        SET @iso = RIGHT(@s, 4) + '-' + LEFT(@s, 2) + '-' + SUBSTRING(@s, 4, 2);
    ELSE IF @s LIKE '[0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
    BEGIN
        SET @yy = CAST(RIGHT(@s, 2) AS INT);
        SET @iso = CAST(CASE WHEN @pivot IS NULL OR @yy <= @pivot THEN 2000 + @yy ELSE 1900 + @yy END AS VARCHAR(4))
                   + '-' + LEFT(@s, 2) + '-' + SUBSTRING(@s, 4, 2);
    END
    ELSE IF @s LIKE '[0-9][0-9]-[A-Za-z][A-Za-z][A-Za-z]-[0-9][0-9][0-9][0-9]'
    BEGIN
        SET @pos = CHARINDEX(UPPER(SUBSTRING(@s, 4, 3)), @months);
        IF @pos > 0 AND (@pos - 1) % 3 = 0
        BEGIN
            SET @m = (@pos + 2) / 3;
            SET @iso = RIGHT(@s, 4) + '-' + RIGHT('0' + CAST(@m AS VARCHAR(2)), 2) + '-' + LEFT(@s, 2);
        END
    END
    ELSE IF @s LIKE '[A-Za-z]%[ ][0-9][0-9],[ ][0-9][0-9][0-9][0-9]'
    BEGIN
        SET @pos = CHARINDEX(UPPER(LEFT(@s, 3)), @months);
        IF @pos > 0 AND (@pos - 1) % 3 = 0
        BEGIN
            SET @m = (@pos + 2) / 3;
            SET @iso = RIGHT(@s, 4) + '-' + RIGHT('0' + CAST(@m AS VARCHAR(2)), 2) + '-'
                       + SUBSTRING(@s, CHARINDEX(' ', @s) + 1, 2);
        END
    END

    RETURN TRY_CONVERT(DATE, @iso, 23);
END;
GO

DROP FUNCTION IF EXISTS silver.fn_icd;
GO
CREATE FUNCTION silver.fn_icd (@c NVARCHAR(100))
RETURNS VARCHAR(50)
AS
BEGIN
    -- Normaliza un codigo ICD: mayusculas, sin espacios, 'K21-9' / 'M545' -> 'K21.9' / 'M54.5'
    SET @c = UPPER(LTRIM(RTRIM(@c)));
    IF @c IS NULL OR @c = N'' RETURN NULL;
    SET @c = REPLACE(@c, '-', '.');
    IF CHARINDEX('.', @c) = 0 AND LEN(@c) > 3
        SET @c = LEFT(@c, 3) + '.' + SUBSTRING(@c, 4, 50);
    RETURN CAST(@c AS VARCHAR(50));
END;
GO

DELETE FROM silver.cuarentena;
DELETE FROM silver.billing;
DELETE FROM silver.diagnoses;
DELETE FROM silver.admissions;
DELETE FROM silver.patients;
GO

-- ---------------------------------------------------------------------------
-- 8.1 PACIENTES
-- ---------------------------------------------------------------------------
INSERT INTO silver.patients (patient_id, full_name, gender, date_of_birth, phone, email, address, insurance_provider)
SELECT
    TRY_CAST(b.patient_id AS INT),
    LTRIM(RTRIM(b.full_name)),
    CASE UPPER(LTRIM(RTRIM(b.gender)))
        WHEN 'M' THEN 'Male' WHEN 'MALE' THEN 'Male'
        WHEN 'F' THEN 'Female' WHEN 'FEMALE' THEN 'Female'
        ELSE NULL END,
    CASE WHEN d.dob >= '1900-01-01' AND d.dob <= CAST(GETDATE() AS DATE) THEN d.dob END,
    CASE WHEN LEN(t.d10) = 10 AND t.d10 NOT LIKE '%[^0-9]%'
         THEN LEFT(t.d10, 3) + '-' + SUBSTRING(t.d10, 4, 3) + '-' + RIGHT(t.d10, 4) END,
    CASE WHEN e.e2 LIKE '_%@_%._%' AND e.e2 NOT LIKE '% %' AND e.e2 NOT LIKE '%@%@%' THEN e.e2 END,
    LTRIM(RTRIM(b.address)),
    CASE i.k
        WHEN 'MEDICAID' THEN 'Medicaid'
        WHEN 'MEDICARE' THEN 'Medicare'
        WHEN 'CIGNA' THEN 'Cigna' WHEN 'CIGNAHEALTH' THEN 'Cigna'
        WHEN 'UNITEDHEALTH' THEN 'UnitedHealth' WHEN 'UHC' THEN 'UnitedHealth'
        WHEN 'BLUECROSS' THEN 'BlueCross'
        WHEN 'SELFPAY' THEN 'Self Pay'
        WHEN 'AETNA' THEN 'Aetna' WHEN 'AETNAINC' THEN 'Aetna' WHEN 'AETNAA' THEN 'Aetna'
        WHEN 'NONE' THEN 'Uninsured'
        ELSE 'Unknown' END
FROM bronze.patients b
CROSS APPLY (SELECT silver.fn_parse_date(b.date_of_birth, 26) AS dob) d
CROSS APPLY (SELECT REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(LTRIM(RTRIM(b.phone)), '(', ''), ')', ''), '-', ''), '.', ''), ' ', ''), '+', '') AS d) p
CROSS APPLY (SELECT CASE WHEN LEN(p.d) = 11 AND LEFT(p.d, 1) = '1' THEN RIGHT(p.d, 10) ELSE p.d END AS d10) t
CROSS APPLY (SELECT REPLACE(REPLACE(REPLACE(LOWER(LTRIM(RTRIM(b.email))), ' at ', '@'), ',', '.'), 'gmial', 'gmail') AS e2) e
CROSS APPLY (SELECT UPPER(REPLACE(REPLACE(REPLACE(LTRIM(RTRIM(b.insurance_provider)), ' ', ''), '-', ''), '.', '')) AS k) i
WHERE TRY_CAST(b.patient_id AS INT) IS NOT NULL
  AND NULLIF(LTRIM(RTRIM(b.full_name)), '') IS NOT NULL;
GO

INSERT INTO silver.cuarentena (tabla_origen, id_origen, motivo)
SELECT 'patients', b.patient_id, N'patient_id no numerico o nombre vacio'
FROM bronze.patients b
WHERE TRY_CAST(b.patient_id AS INT) IS NULL
   OR TRY_CAST(b.patient_id AS INT) NOT IN (SELECT patient_id FROM silver.patients);
GO

-- ---------------------------------------------------------------------------
-- 8.2 ADMISIONES
-- ---------------------------------------------------------------------------
INSERT INTO silver.admissions (admission_id, patient_id, admission_date, discharge_date, department, attending_doctor_id)
SELECT
    TRY_CAST(b.admission_id AS INT),
    TRY_CAST(b.patient_id AS INT),
    a.adm,
    CASE WHEN a.dis >= a.adm THEN a.dis END,      -- alta anterior al ingreso -> NULL
    CASE dp.k
        WHEN 'GENERALSURGERY' THEN 'General Surgery' WHEN 'GENSURG' THEN 'General Surgery'
        WHEN 'NEUROLOGY' THEN 'Neurology' WHEN 'NUEROLOGY' THEN 'Neurology' WHEN 'NEURO' THEN 'Neurology'
        WHEN 'CARDIOLOGY' THEN 'Cardiology' WHEN 'CARDIOLGY' THEN 'Cardiology' WHEN 'CARDIO' THEN 'Cardiology'
        WHEN 'ORTHO' THEN 'Orthopedics' WHEN 'ORTHOPEDICS' THEN 'Orthopedics' WHEN 'ORTHOPAEDICS' THEN 'Orthopedics'
        WHEN 'EMERGENCY' THEN 'Emergency' WHEN 'EMERGANCY' THEN 'Emergency' WHEN 'ER' THEN 'Emergency'
        WHEN 'PEDIATRICS' THEN 'Pediatrics' WHEN 'PAEDIATRICS' THEN 'Pediatrics' WHEN 'PEDS' THEN 'Pediatrics'
        WHEN 'ONCOLOGY' THEN 'Oncology' WHEN 'ONCOLOGYY' THEN 'Oncology' WHEN 'ONCO' THEN 'Oncology'
        ELSE LTRIM(RTRIM(b.department)) END,
    TRY_CAST(b.attending_doctor_id AS INT)
FROM bronze.admissions b
CROSS APPLY (SELECT silver.fn_parse_date(b.admission_date, NULL) AS adm, silver.fn_parse_date(b.discharge_date, NULL) AS dis) a
CROSS APPLY (SELECT UPPER(REPLACE(LTRIM(RTRIM(b.department)), ' ', '')) AS k) dp
WHERE TRY_CAST(b.admission_id AS INT) IS NOT NULL
  AND TRY_CAST(b.attending_doctor_id AS INT) IS NOT NULL
  AND a.adm IS NOT NULL
  AND TRY_CAST(b.patient_id AS INT) IN (SELECT patient_id FROM silver.patients);
GO

INSERT INTO silver.cuarentena (tabla_origen, id_origen, motivo)
SELECT 'admissions', b.admission_id,
    CASE WHEN silver.fn_parse_date(b.admission_date, NULL) IS NULL THEN N'Fecha de ingreso vacia o invalida'
         WHEN TRY_CAST(b.patient_id AS INT) IS NULL
           OR TRY_CAST(b.patient_id AS INT) NOT IN (SELECT patient_id FROM silver.patients) THEN N'Paciente inexistente (FK)'
         ELSE N'Identificador o medico no numerico' END
FROM bronze.admissions b
WHERE TRY_CAST(b.admission_id AS INT) IS NULL
   OR TRY_CAST(b.admission_id AS INT) NOT IN (SELECT admission_id FROM silver.admissions);
GO

-- ---------------------------------------------------------------------------
-- 8.3 DIAGNOSTICOS (un codigo principal y, si existe, uno secundario)
-- ---------------------------------------------------------------------------
INSERT INTO silver.diagnoses (diagnosis_id, admission_id, icd_code, icd_code_secundario, diagnosis_description, severity)
SELECT
    TRY_CAST(b.diagnosis_id AS INT),
    TRY_CAST(b.admission_id AS INT),
    silver.fn_icd(c.c1),
    CASE WHEN c.c2 <> N'' THEN silver.fn_icd(c.c2) END,
    NULLIF(LTRIM(RTRIM(b.diagnosis_description)), ''),
    CASE UPPER(LTRIM(RTRIM(b.severity)))
        WHEN 'MILD' THEN 'Mild' WHEN 'MODERATE' THEN 'Moderate'
        WHEN 'SEVERE' THEN 'Severe' WHEN 'CRITICAL' THEN 'Critical'
        ELSE 'Unknown' END
FROM bronze.diagnoses b
CROSS APPLY (SELECT LTRIM(RTRIM(b.icd_code)) + N',' AS s) x
CROSS APPLY (SELECT LTRIM(RTRIM(LEFT(x.s, CHARINDEX(N',', x.s) - 1))) AS c1,
                    LTRIM(RTRIM(REPLACE(SUBSTRING(x.s, CHARINDEX(N',', x.s) + 1, 200), N',', N''))) AS c2) c
WHERE TRY_CAST(b.diagnosis_id AS INT) IS NOT NULL
  AND c.c1 <> N''
  AND TRY_CAST(b.admission_id AS INT) IN (SELECT admission_id FROM silver.admissions);
GO

INSERT INTO silver.cuarentena (tabla_origen, id_origen, motivo)
SELECT 'diagnoses', b.diagnosis_id,
    CASE WHEN NULLIF(LTRIM(RTRIM(b.icd_code)), '') IS NULL THEN N'Codigo ICD vacio'
         ELSE N'Admision inexistente (FK)' END
FROM bronze.diagnoses b
WHERE TRY_CAST(b.diagnosis_id AS INT) IS NULL
   OR TRY_CAST(b.diagnosis_id AS INT) NOT IN (SELECT diagnosis_id FROM silver.diagnoses);
GO

-- ---------------------------------------------------------------------------
-- 8.4 FACTURACION
-- ---------------------------------------------------------------------------
INSERT INTO silver.billing (billing_id, admission_id, charge_type, amount, payment_status, payment_date)
SELECT
    TRY_CAST(b.billing_id AS INT),
    TRY_CAST(b.admission_id AS INT),
    COALESCE(NULLIF(LTRIM(RTRIM(b.charge_type)), ''), 'Unknown'),
    CAST(ROUND(m.amt, 2) AS DECIMAL(12, 2)),
    CASE UPPER(LTRIM(RTRIM(b.payment_status)))
        WHEN 'PAID' THEN 'Paid' WHEN 'UNPAID' THEN 'Unpaid'
        WHEN 'PENDING' THEN 'Pending' WHEN 'OVERDUE' THEN 'Overdue'
        ELSE 'Unknown' END,
    silver.fn_parse_date(b.payment_date, NULL)
FROM bronze.billing b
CROSS APPLY (SELECT TRY_CAST(NULLIF(LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(UPPER(b.amount), 'USD', ''), '$', ''), ',', ''))), '') AS DECIMAL(18, 6)) AS amt) m
WHERE TRY_CAST(b.billing_id AS INT) IS NOT NULL
  AND m.amt IS NOT NULL AND m.amt < 9999999999
  AND TRY_CAST(b.admission_id AS INT) IN (SELECT admission_id FROM silver.admissions);
GO

INSERT INTO silver.cuarentena (tabla_origen, id_origen, motivo)
SELECT 'billing', b.billing_id,
    CASE WHEN NULLIF(LTRIM(RTRIM(b.amount)), '') IS NULL THEN N'Monto vacio'
         ELSE N'Admision inexistente (FK) o monto invalido' END
FROM bronze.billing b
WHERE TRY_CAST(b.billing_id AS INT) IS NULL
   OR TRY_CAST(b.billing_id AS INT) NOT IN (SELECT billing_id FROM silver.billing);
GO

PRINT 'Silver cargada.';
GO
