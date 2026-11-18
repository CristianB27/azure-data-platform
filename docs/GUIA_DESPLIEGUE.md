# Guía de despliegue, uso y destrucción · Proyecto 09

Esta guía explica cómo reproducir la plataforma desde cero, cómo probarla y cómo apagar lo que cuesta dinero. Los nombres corresponden al despliegue real: sufijo aleatorio `461l`, región `eastus2` y Synapse en `centralus`.

> Los comandos marcados como *referencia* son la forma estándar de hacer el paso. No son una transcripción literal de lo que ejecutó el equipo.

---

## 1. Pre-requisitos

| Necesitas | Versión / detalle |
|---|---|
| Suscripción de Azure activa | Con permiso para asignar roles (Owner, o Contributor + User Access Administrator) |
| Organización y proyecto en Azure DevOps | Proyecto `proyecto09`, con paralelismo de agentes hospedados |
| Repositorio en GitHub | `CristianB27/azure-data-platform`, conectado a Azure DevOps |
| Terraform | 1.9.8 (el pipeline lo instala solo; en local solo hace falta para pruebas) |
| Azure CLI | Reciente, con `az login` |
| Python | 3.x (el equipo usó 3.12), para el generador y los scripts de CSV |
| Git + Git Bash o VS Code | Ver la sección 8 sobre pegar comandos en Git Bash |

**Proveedores de recursos** que deben estar registrados en la suscripción:

```bash
for ns in Microsoft.Storage Microsoft.EventHub Microsoft.StreamAnalytics Microsoft.DataFactory \
          Microsoft.Synapse Microsoft.Sql Microsoft.Network Microsoft.Insights \
          Microsoft.OperationalInsights Microsoft.Consumption Microsoft.Authorization; do
  az provider register --namespace "$ns"
done
az provider list --query "[?registrationState=='Registered'].namespace" -o tsv   # verificar
```

---

## 2. Preparación previa (una sola vez)

### 2.1 Estado remoto de Terraform

Debe coincidir con `terraform/backend.tf`: grupo `rg-tfstate`, cuenta `stp09utbtfstate01`, contenedor `tfstate` y clave `p09utb.tfstate`, con autenticación Azure AD.

```bash
# referencia
az group create -n rg-tfstate -l eastus2
az storage account create -n stp09utbtfstate01 -g rg-tfstate -l eastus2 --sku Standard_LRS --min-tls-version TLS1_2
az storage container create -n tfstate --account-name stp09utbtfstate01 --auth-mode login
```

### 2.2 Service Connection con federación de identidad (sin secretos)

1. Azure DevOps → *Project settings* → *Service connections* → *New* → **Azure Resource Manager** → **Workload Identity Federation (automatic)**.
2. Nombre: **`sc-p09utb-azure`**, con alcance en la suscripción. Azure DevOps crea el *App registration* (en el proyecto real, App ID `406fc165-9fe0-46eb-b2be-516a9026e240`).
3. Asigna a esa identidad estos roles:
   - **Contributor** y **User Access Administrator** sobre la suscripción. El segundo es necesario porque Terraform crea asignaciones de roles.
   - **Storage Blob Data Contributor** sobre `stp09utbtfstate01`, para leer y escribir el estado con Azure AD.

No se guarda ningún *client secret*. En cada ejecución, el pipeline recibe un token OIDC de corta duración (`$idToken` → `ARM_OIDC_TOKEN`).

### 2.3 Environment con aprobación manual

*Pipelines* → *Environments* → *New* → **`production`** → *Approvals and checks* → *Approvals* → agrega al aprobador. La primera ejecución pide **Permit** para usar el environment; después queda guardado.

### 2.4 Variable secreta de Synapse

En el pipeline (*Edit* → *Variables*), crea **`TF_VAR_synapse_admin_password`** y márcala como **secreta**.

> Azure DevOps **no** expone las variables secretas como variables de entorno por su cuenta. Por eso `azure-pipelines.yml` la mapea explícitamente en el bloque `env:` del paso *Terraform plan*. El archivo `tfplan` contiene ese valor: nunca se sube al repo, y el artefacto del pipeline es privado.

### 2.5 Pipeline

*Pipelines* → *New pipeline* → GitHub → el repositorio → *Existing Azure Pipelines YAML file* → `/azure-pipelines.yml`.

---

## 3. Despliegue

### 3.1 Flujo de trabajo

```
rama faseN  →  Pull Request a main  →  validate + plan (el apply aparece "Skipped")
            →  merge  →  validate + plan + apply  →  aprobación en "production"  →  Azure
```

- El pipeline se dispara con cambios en `terraform/*` o `azure-pipelines.yml` en `main`. En un PR, solo con cambios en `terraform/*`.
- **Antes de aprobar el apply, revisa el plan.** Mira el log del paso *Terraform plan* (`N to add, N to change, N to destroy`).
- Un `1 to change` persistente en el pipeline de Data Factory es inofensivo: Azure normaliza `dataFlow`/`dataflow` y agrega `compressionProperties = null`.

### 3.2 Orden recomendado desde cero

| Paso | Qué se crea | deployExpensive |
|---|---|---|
| 1 | Grupo, Data Lake con capas y lifecycle, storage auxiliar con tabla y origen | desmarcado |
| 2 | Data Factory: linked services, datasets, Data Flows, pipelines y triggers desactivados | desmarcado |
| 3 | Synapse, roles por contenedor, Synapse Administrator para el usuario | desmarcado |
| 4 | Log Analytics, diagnósticos, alerta de ADF, presupuesto | desmarcado |
| 5 | Event Hubs, Stream Analytics, sus alertas, la red privada y el Private Endpoint | **marcado** (solo mientras se prueba) |

En la práctica, un único `apply` desde `main` crea los pasos 1 a 4 de una vez. El paso 5 se activa con la casilla.

### 3.3 Recursos costosos: el interruptor deployExpensive

*Run pipeline* → rama `main` → marca **deployExpensive** → *Run* → aprueba el apply. Se crean Event Hubs, Stream Analytics (con sus alertas y diagnóstico) y la red privada con el Private Endpoint (≈ USD 0.15/h en total, **estimado**). El texto de la casilla solo menciona Event Hubs y Stream Analytics, pero también crea la red. Es un detalle cosmético.

Stream Analytics arranca solo al desplegarse (`azurerm_stream_analytics_job_schedule`).

---

## 4. Pasos manuales posteriores

### 4.1 Synapse (una vez)

1. Abre Synapse Studio en `syn-p09utb-461l`. Si aparece *"No tiene acceso al grupo de SQL sin servidor integrado"*, revisa que tu usuario sea **Synapse Administrator** (`azurerm_synapse_role_assignment.admin_usuario` en `terraform/synapse.tf`, con tu Object ID).
2. Abre [`sql/synapse_vistas.sql`](../sql/synapse_vistas.sql) y ejecuta los bloques **por separado** y en orden, conectado a **Integrado**:
   - Bloque A, en `master`: `CREATE DATABASE p09utb`.
   - Bloque B, en `p09utb`: llave maestra (reemplaza el marcador `<ClaveCualquiera1!>`), credencial `cred_msi` (Managed Identity) y data source `ds_lake`.
   - Bloque C: las cuatro vistas, cada `CREATE VIEW` por separado (Synapse Studio no usa `GO`).
   - Bloques D y E: verificaciones y las tres consultas analíticas.

### 4.2 Ejecutar los pipelines de Data Factory

Data Factory Studio → *Author* → `pl_batch_medallion` → **Add trigger → Trigger now**. Sigue la ejecución en *Monitor → Pipeline runs*. Para la ruta streaming, haz lo mismo con `pl_streaming_medallion`.

- Los triggers `tr_diario_2am` (2:00 AM, SA Pacific Standard Time) y `tr_streaming_horario` se crearon **desactivados** para controlar el costo.
- **Espera a que termine el `apply`** antes de lanzar un pipeline. Si no, se ejecuta la definición anterior.
- Cada ejecución de Data Flow cuesta ≈ USD 0.4–0.8 (**estimado**). El runtime `ir-dataflow` reutiliza el clúster durante 5 minutos.

### 4.3 Generador de eventos (solo con deployExpensive activo)

Variables que lee `src/generator/generator.py`:

| Variable | Obligatoria | Valor |
|---|---|---|
| `EVENTHUB_CONN` | sí | Cadena de conexión del namespace `evh-p09utb-461l` (*Shared access policies → RootManageSharedAccessKey*). **Es un secreto: no la guardes en archivos del repo.** |
| `EVENTHUB_NAME` | no | `telemetria` (valor por defecto) |

```bash
pip install -r src/generator/requirements.txt      # azure-eventhub==5.12.1
export EVENTHUB_CONN='<cadena de conexión>'          # solo en la sesión actual
python src/generator/generator.py --seconds 300      # 1 lectura/s de un sensor al azar entre 5
```

Si aparece `ParentResourceNotFound`, Event Hubs todavía no existe: despliega primero con deployExpensive.

Los agregados aparecen en `bronze/streaming/agregados/{fecha}/{hora}/` (en UTC), y las alertas con `MAX(temperature) > 30` en la tabla `alertas` de `stp09utbaux461l`. Después ejecuta `pl_streaming_medallion` para llevar los datos a Silver y Gold.

---

## 5. Pruebas y evidencias

### 5.1 Quality gate (bloqueo por nulos)

```bash
python scripts/generar_csv_malo.py
# crea data/malo/telemetria.csv (40 % de nulos en cada columna) y data/bueno/telemetria.csv (copia del original)
```

1. Sobrescribe `origen/telemetria.csv` en `stp09utbaux461l` con `data/malo/telemetria.csv`, desde el portal o con `az storage blob upload --overwrite`. Necesitas permiso de escritura sobre esa cuenta.
2. *Trigger now* sobre `pl_batch_medallion`. Resultado esperado: `validar_calidad` falla, `bloquear_promocion` termina en **Error** con el código **CalidadDatos** y llega el correo de `alert-adf-fallos`.
3. Restaura con `data/bueno/telemetria.csv` y vuelve a ejecutar. Resultado esperado: **Succeeded**, con las 6 actividades en verde.

Valores reales que devolvió `leer_metricas`: con el lote malo, total 1 020, nulos 937 y distintos 361 (bloqueado). Con el lote bueno, total 1 020, nulos 31 y distintos 986 (promovido).

> Cambiar el CSV es un cambio de **datos**, no de infraestructura. `data/malo/` y `data/bueno/` están en `.gitignore`.

### 5.2 Alertas de Stream Analytics

Con deployExpensive activo: deja el job corriendo sin enviar eventos (se dispara `alert-asa-sin-eventos`), ejecuta el generador (se resuelve) y detenlo (se vuelve a disparar). Los correos llegan a la dirección de `var.alert_email`.

> Una alerta de métrica **no** se dispara si el job se detiene por completo, porque deja de emitir la métrica.

### 5.3 Permisos por capa

En Synapse, la consulta comentada al final de `sql/synapse_vistas.sql` (sobre `bronze/batch`) debe **fallar por permisos**: Synapse solo tiene *Storage Blob Data Reader* en silver y gold. Si justo después de cambiar los roles todavía funciona, es la caché del token de la identidad administrada: espera y vuelve a intentar.

### 5.4 Consultas analíticas

Bloque E de `sql/synapse_vistas.sql`: tendencia diaria, top-3 de sensores por temperatura máxima y resumen por sensor. La consulta de convergencia (`vw_gold_unificada` agrupada por `fuente`) está en el bloque D.

---

## 6. Destrucción y control de costos

**Apagar lo costoso (lo habitual):** *Run pipeline* → `main` → **desmarca** deployExpensive → *Run* → revisa que el plan **solo destruya** Event Hubs, Stream Analytics, sus alertas y diagnóstico, y la red privada → aprueba.

Comprueba que quedó apagado:

```bash
az resource list -g rg-p09utb-data -o table    # no deben aparecer evh-, asa-, vnet-, pe-
```

**Destruir todo** (al final del curso):

```bash
# referencia, desde terraform/ con sesión de Azure y acceso al estado remoto
terraform init
TF_VAR_synapse_admin_password='<la misma>' terraform destroy
```

Después borra, si ya no se usa, el grupo `rg-tfstate`, que guarda el estado.

**Presupuesto:** `budget-p09utb` (USD 20/mes) envía avisos al 50 %, 80 % y 100 % real y al 100 % proyectado. Míralo en *Cost Management* con el **ámbito de la suscripción**: en el de la cuenta de facturación la lista aparece vacía. El crédito de prueba (USD 200) venció el 28-oct-2026. Antes de redesplegar, verifica que la suscripción siga *Enabled*.

---

## 7. Problemas frecuentes

| # | Síntoma | Causa | Solución |
|---|---|---|---|
| 1 | Comandos rotos con `^[[200~` en Git Bash | *Bracketed paste* de la terminal; también se mezcló sintaxis de PowerShell | Pegar una línea a la vez o escribirla; usar la sintaxis de la shell correcta |
| 2 | `Author identity unknown` | Git sin nombre ni correo | `git config user.name` / `user.email` |
| 3 | Rama con nombre cortado (`fase1-st`) | Error al teclear | `git branch -m fase1-streaming` |
| 4 | `ParentResourceNotFound` al correr el generador | Event Hubs aún no existía | Desplegar con deployExpensive antes de generar |
| 5 | ADF `DelimitedTextInvalidSettings` | Faltaba el delimitador de fila del CSV | `row_delimiter = "\n"` (PR #3) |
| 6 | El If no lee `runStatus.output.metricasSink` | Esa propiedad no existe en la salida del Data Flow | Escribir las métricas en Parquet y leerlas con Lookup `firstRow` (PR #4) |
| 7 | Una ejecución usa la definición vieja | Se lanzó antes de terminar el apply | Esperar al apply |
| 8 | El apply aparece *Skipped due to conditions* en un PR | Es lo esperado: el apply solo corre en `main` | Merge y aprobar; un PR sin cambios en `/terraform` no dispara el pipeline |
| 9 | Terraform pide `synapse_admin_password` | Las variables secretas no llegan como variables de entorno | Mapearla en `env:` del paso plan |
| 10 | `SqlServerRegionDoesNotAllowProvisioning` | La suscripción no podía crear SQL en eastus2 | Synapse en `centralus` (`var.synapse_location`) |
| 11 | Synapse Studio sin acceso al pool serverless | El creador del workspace fue la identidad del pipeline | `azurerm_synapse_role_assignment` (Synapse Administrator) |
| 12 | Presupuestos vacíos | Se miraba el ámbito de la cuenta de facturación | Cambiar al ámbito de la suscripción |
| 13 | `1 to change` permanente y avisos de depreciación | Azure normaliza el JSON del pipeline; `storage_account_name` está deprecado | Inofensivo; se puede migrar a `storage_container_id` |
| 14 | Synapse seguía leyendo Bronze tras quitar el rol | Un rol amplio en la cuenta anulaba la restricción, y luego la caché del token | Roles por contenedor; esperar a que expire el token |
| 15 | `MI auth not supported… Storage (general purpose v1)` | El linked service Blob suponía una cuenta v1 | `storage_kind = "StorageV2"` (PR #14) |
| 16 | Requisitos del PDF sin cubrir detectados tarde | No se contrastó el plan con el PDF a tiempo | Se completaron en las fases 5, 10 y 11; contrastar antes de destruir recursos |
| 17 | La alerta de ASA no se dispara con el job detenido | El job detenido no emite la métrica | Limitación documentada |
