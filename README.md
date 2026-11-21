# Data Warehouse hospitalario en Azure (Bronze / Silver / Gold)

Despliegue con Terraform de un Azure SQL Database (`dw_hospital`) con arquitectura medallion:

| Capa | Contenido |
|------|-----------|
| bronze | Datos crudos de los CSV (pacientes, admisiones, diagnosticos, facturacion), todo como texto |
| silver | Datos limpios y tipados con llaves PK/FK; las filas invalidas van a `silver.cuarentena` |
| gold | Modelo estrella: 5 dimensiones y 2 tablas de hechos (admisiones y facturacion) |

## Scripts (`sql/`, se ejecutan en orden desde `main.tf`)
1. `1_bronze.sql`, `2_silver.sql`, `3_gold.sql`: esquemas y tablas.
2. `4` a `7`: carga cruda en bronze.
3. `8_silver_load.sql`: limpieza (fechas en 5 formatos, genero, aseguradoras, departamentos, ICD, montos, emails y telefonos) y cuarentena.
4. `9_gold_load.sql`: dimensiones y hechos.
5. `10_verificacion.sql`: conteos por capa (manual).

## Uso
Definir las variables `ARM_*` en la terminal y ejecutar `terraform init`, `terraform plan`, `terraform apply`.
