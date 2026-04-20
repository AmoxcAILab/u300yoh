# Estrategia de Observabilidad

## Cadena de procesamiento para la recuperación de texto manuscrito histórico
### Unlocking 300 years of history
### Flotas de la Nueva España

**Versión 1.2 — Marzo 2026**

## Introducción y objetivos
Este documento define la estrategia de observabilidad para la cadena de procesamiento de texto manuscrito histórico del proyecto _Unlocking 300 years of history_ y, potencialmente, del proyecto _Flotas de la Nueva España_ del **Laboratorio de Inteligencia Artificial para Humanidades Digitales** en la universidad **Tecnológico de Monterrey**, que abarca desde la compilación de imágenes de documentos manuscritos de los siglos XVI, XVII y XVIII disponibles públicamente en los archivos del [Archivo General de la Nación](https://www.gob.mx/agn) mexicana y del [Archivo General de Indias](https://www.cultura.gob.es/cultura/areas/archivos/mc/archivos/agi/portada.html) hasta la producción de un corpus de texto en español contemporáneo. La cadena de procesamiento está diseñada para ser aplicada sobre miles de documentos en una infraestructura que combina recursos del Laboratorio, servicios de terceros y un clúster de investigación provisto por **Schmidt Sciences** para el entrenamiento de modelos de inteligencia artificial.

La estrategia de observabilidad tiene como objetivos:

- Consolidar un modelo de datos unificado que pueda aprovechar al máximo los recursos disponibles sin comprometer la integridad de la información.
- Identificar documentos que no cumplan los criterios de transcripción a través de la cadena de procesamiento, generar alertas y tareas para el equipo de expertos en la interpretación histórica del corpus.
- Calcular métricas automáticas (CER, WER, BLEU, ChrF++) y garantizar la trazabilidad de los documentos.
- Ofrecer visualizaciones y formas de interacción con el modelo unificado de datos diferenciadas para el equipo de procesamiento y para equipo de análisis.
- Habilitar un ciclo de retroalimentación desde una interfaz para la anotación manual hacia la cadena de recuperación de texto. 
- Garantizar visibilidad, reproducibilidad y trazabilidad de las transformaciones aplicadas a cada documento.

## Arquitectura de la infraestructura
### Arquitectura actual
![[assets/image/resources/architecture.svg]]

El diagrama muestra la arquitectura actual del proyecto en febrero de 2026, compuesta por siete componentes principales que operan de forma fragmentada y sin integración automatizada entre sí. Los dos repositorios de GitHub contienen respectivamente el corpus de documentos históricos (Ground Truth, outputs HTR por tipo de letra y el training set del clasificador) y el código del pipeline de limpieza `htr_cleaning`, que incluye los scripts de procesamiento, utilidades y esquemas. Supabase alberga dos bases de datos desconectadas entre sí: la principal con el esquema de documentos, modelos y colaboradores, y una segunda destinada a abreviaturas cuyo esquema está aún por confirmar. El servidor Schmidt Sciences provee GPUs para inferencia y entrenamiento, gestiona entornos con nix y orquesta jobs con slurm, aunque sin acceso root y sin conexión directa a Supabase. Completan el cuadro el Anotador, una aplicación con frontend y backend propios que no sincroniza con Supabase, y N8N como orquestador aún por definir y configurar.

La dificultad principal reside en que ninguno de estos componentes está conectado de forma automatizada. El pipeline se ejecuta manualmente desde la CLI del cluster, sin logging centralizado ni métricas de calidad post-HTR. Los datos están fragmentados entre las dos instancias de Supabase, la base de datos local del Anotador, y cuatro servicios de almacenamiento externos (AGI/AGN, Google Drive/OneDrive, Transkribus y disco local) donde los documentos existen en múltiples copias sin fuente de referencia única, lo que introduce fricción y riesgo de error cada vez que se mueven archivos entre servicios. A esto se suma que el clasificador de tipo de letra tiene training set pero no está integrado al pipeline, no existe una KB (Knowledge Base) para RAG, las correcciones del equipo de análisis no retornan al pipeline, y Basecamp gestiona la coordinación del proyecto de forma completamente aislada del resto de la infraestructura.

### Principios de diseño
- **Base de datos local como fuente de referencia única.** Toda la trazabilidad, métricas, resultados de revisión humana y estado de los documentos viven en esta base de datos.
- **Las tablas de observabilidad se integran en el schema `public` existente** y se anclan a `Documents` vía `doc_id` como FK, respetando el modelo de datos ya establecido.
- **Las tablas existentes no se modifican.** La observabilidad se añade sin alterar `ML_Models_Key`, `NLP_Annotation`, `Collaborators` ni ninguna otra tabla existente. Las nuevas tablas referencian las existentes; no al revés.
- **Nix gestiona todos los entornos.** Los entornos de Python para el pipeline y la aplicación de anotación se declaran como entornos nix reproducibles.
- **slurm gestiona toda la computación** Los scripts de observabilidad corren como pasos finales de cada paso del procesamiento.

### Cadena de procesamiento
#### Inicialización
Antes de procesar cualquier documento, el sistema verifica si la base de conocimiento existe. Si no existe, corre el JOB 0 de forma idempotente: construye KB-1 desde el diccionario de abreviaturas migrado de Supabase y ejemplos en contexto extraídos del GT; construye KB-3 corriendo NER sobre los 157 documentos del GT más `public.Places`, agrupando variantes ortográficas bajo formas canónicas y marcando todas las entidades como `verified = true`. KB-2 se inicializa vacía y permanece inactiva hasta que el Anotador acumule suficientes pares de modernización. Las tres KBs viven en pgvector dentro de la misma instancia PostgreSQL del servidor Schmidt Sciences.

#### Procesamiento por lote
Cada documento entra por el PASO 0, donde se crea su registro en `public.Documents` con los metadatos del origen — colección AGI o AGN, serie, siglo, rango de folios y ruta de imágenes. Este registro es el ancla de todo lo que sigue; si no existe, el documento no puede continuar.

El _PASO 1_ ajusta brillo y contraste produciendo la imagen procesada que usan todos los pasos posteriores. El PASO 2 llama a la API de Transkribus para obtener el layout analysis — regiones y líneas sin texto aún. El PASO 3 corre el clasificador con la imagen procesada y el XML de layout, asignando un tipo de letra y una confianza por página, ambos registrados en `pipeline_document_trace`. El PASO 4 llama de nuevo a Transkribus para el HTR usando el modelo que corresponde al tipo de letra detectado.

PC-1 verifica que el `doc_id` exista en la base de datos — validación defensiva porque el PASO 0 ya lo garantizó — y calcula el CER baseline contra el GT si el documento tiene transcripción de referencia. Un documento sin registro válido se rechaza aquí con log y no continúa.

El _PASO 5_ corre el pipeline de limpieza en tres fases: heurísticas de normalización, expansión de abreviaturas ambiguas vía RAG-1 recuperando ejemplos de KB-1 filtrados por tipo de letra y siglo, y normalizaciones restantes. PC-2 mide el delta CER/WER respecto al HTR crudo — si es negativo el documento recibe flag de carril amarillo pero siempre continúa, porque este control es informativo, no bloqueante.

El _PASO 6_ corre HistClean-SpA con validación de entidades vía RAG-3. Por cada entidad que NER detecta en el texto, el retriever hace primero una búsqueda normal con umbral de confianza alto en KB-3. Si no encuentra match suficiente, amplía el radio semántico buscando entidades del mismo tipo, periodo y región. El resultado es uno de tres: match verificado, match parcial con confianza media, o sin ningún match. Al terminar, el documento tiene un resumen de `n_verified`, `n_partial` y `n_unmatched` en `pipeline_document_trace`, y el `clean_text` se guarda siempre en disco independientemente de lo que decida PC-3.

PC-3 toma la decisión de enrutamiento en dos pasos. Primero pregunta si `n_unmatched` supera `umbral_bloqueo` definido en `pipeline_config`: si sí, el documento queda bloqueado y no avanza al PASO 7; va directamente al Anotador con prioridad alta. Si no supera el umbral, pregunta si hay algún `n_partial` o `n_unmatched` residual: si sí, el documento avanza al PASO 7 pero con `status = provisional`, lo que significa que su output existirá pero no entrará al corpus final hasta validación. Si ambas condiciones son falsas, el documento es limpio y avanza sin restricciones.

El _PASO 7_ corre Hist2Mod-SpA sobre todos los documentos que llegaron — limpios y provisionales. Si KB-2 tiene suficientes pares, RAG-2 detecta tokens de baja frecuencia y los moderniza con contexto recuperado de pares validados. El output se guarda en `modern-text/`. PC-4 mide BLEU, ChrF++ y compliance filológica; si `entity_preservation` cae bajo el 98% el documento entra al carril rojo. PC-5 cierra el lote calculando el SHA-256 de cada documento, generando el reporte de cobertura por carril, tipo de letra y serie, y marcando `pipeline_runs.status = completed`.

#### Salidas y retroalimentación

Los documentos limpios están disponibles inmediatamente en el corpus. Los provisionales y bloqueados van al Anotador. En el Anotador, los bloqueados tienen prioridad alta — el anotador ve cada entidad no verificada con su fragmento de contexto y el match parcial si existe, y puede confirmarla o corregirla. Cada entidad confirmada entra a KB-3 con `verified = true`. Cada corrección de modernización genera un par que entra a KB-2. Los scores de revisión alimentan `pipeline_human_review`. Los ajustes de umbral van a `pipeline_config` en ciclo corto. Los documentos marcados como `is_training_candidate` disparan el ciclo largo de fine-tuning que actualiza `ML_Models_Key`.

### Diagrama de flujo
![[assets/image/resources/diagram_flow_pipeline.svg]]


## Arquitectura de observabilidad

La observabilidad se organiza en tres capas que atraviesan todas las fases de la cadena de procesamiento:

| Capa                               | Responsable          | Implementación                                             | Frecuencia               |
|:---------------------------------- |:-------------------- |:---------------------------------------------------------- |:------------------------ |
| Capa 1: Métricas de calidad NLP    | Equipo CS/ML         | Scripts Python + Base de datos (`pipeline_run_metrics`)    | Por lote / por documento |
| Capa 2: Trazabilidad por documento | Equipo CS/ML + Infra | Base de datos (`pipeline_document_trace`)                  | Por documento            |
| Capa 3: Revisión humana y feedback | Anotadores + CS      | Aplicación de anotación → Base de datos (`pipeline_human_review`) | Bajo demanda             |

### Tablas existentes y nuevas tablas necesarias

| Necesidad                                      | Tabla existente que ya cubre esto     | Tabla nueva necesaria     |
|:---------------------------------------------- |:------------------------------------- |:------------------------- |
| Identidad del documento                        | `Documents`                           | —                         |
| Estado del HTR en Transkribus                  | `HRT_Status` + `Transkribus_Workflow` | —                         |
| Modelos ML y sus métricas de entrenamiento     | `ML_Models_Key`                       | —                         |
| Qué modelo se usó en qué documento             | `Model_Use`                           | —                         |
| Anotadores y revisores humanos                 | `Collaborators`                       | —                         |
| Estado de anotación NLP                        | `NLP_Annotation`                      | —                         |
| Ejecuciones del pipeline                       | —                                     | `pipeline_runs`           |
| Métricas de calidad por documento (CER, BLEU…) | —                                     | `pipeline_document_trace` |
| Métricas agregadas por lote                    | —                                     | `pipeline_run_metrics`    |
| Cola de revisión priorizada                    | —                                     | `pipeline_review_queue`   |
| Resultados de revisión humana estructurada     | —                                     | `pipeline_human_review`   |
| Umbrales configurables del pipeline            | —                                     | `pipeline_config`         |


## Puntos de control

El ciclo de procesamiento tiene cinco puntos de control donde se capturan métricas, se registran metadatos y se toman decisiones de enrutamiento. Cada punto de control es el último paso de su job slurm correspondiente.

### PC-1 | Entrada: HTR Output

**job slurm:** `job_phase_1_ingest.sh`

- Verificar que cada `doc_id` existe en `public.Documents` — documentos sin registro se rechazan con log antes de procesar
- Verificar integridad del archivo (encoding UTF-8, longitud mínima de texto)
- Calcular línea base de CER/WER del HTR crudo contra GT disponible
- Registrar en `pipeline_runs`: inicio del lote, versiones de modelos, total de documentos
- Subir texto HTR a Base de datos: `path: htr-raw/{run_id}/{doc_id}.txt`

### PC-2 | Post-Heurísticas: HTR → Heuristic_Cleaned

**job slurm:** `job_phase_2_heuristics.sh`

- Calcular delta CER/WER (mejora respecto a HTR crudo)
- Contar y clasificar reglas aplicadas por documento
- Detectar documentos donde las heurísticas empeoran el resultado (delta negativo → carril amarillo automático)
- Guardar diff en Base de datos: `path: diffs/{run_id}/{doc_id}_heur.diff`
- Escribir métricas en `pipeline_document_trace` y `pipeline_run_metrics`

### PC-3 | Post-HistClean-SpA: Heuristic_Cleaned → Early-Modern Limpio

**job slurm:** `job_phase_3_histclean.sh`

- CER objetivo: **< 3%**
- Tasa de expansión correcta de abreviaturas: objetivo **≥ 95%**
- Verificar preservación de entidades históricas
- Documentos con CER > umbral → `carril = rojo`, encolar en `pipeline_review_queue`
- El `Mod_ID` y `Model_Version` del modelo HistClean-SpA se toman de `ML_Models_Key` y se registran en `pipeline_document_trace`

### PC-4 | Post-Hist2Mod-SpA: Early-Modern → Español Moderno

**job slurm:** `job_phase_4_hist2mod.sh`

- BLEU objetivo: **> 70**
- ChrF++ como métrica complementaria
- Compliance checks de las ~25 reglas filológicas
- `entity_preservation < 98%` → carril rojo automático
- El `Mod_ID` y `Model_Version` del modelo Hist2Mod-SpA se registran en `pipeline_document_trace`

### PC-5 | Salida Final: Validación de corpus

**job slurm:** `job_phase_5_validate.sh`

- Estadísticas de cobertura por carril (cruzando con `Document_Dates` e `Instit_Collec_Proj_Key` para contexto de archivo)
- Informe de documentos pendientes en `pipeline_review_queue`
- Hash SHA-256 por documento almacenado en `pipeline_document_trace`
- Marcar `pipeline_runs.status = 'completed'`

## Estrategia de re-entrada de documentos
El principio de diseño es tratar la re-entrada como un nuevo `pipeline_run` vinculado al run original, no como una corrección en caliente del registro existente. Esto preserva la trazabilidad completa.

**Trigger.** PC-5 al cierre de cada lote consulta cuántas entidades nuevas con `verified = true` se han añadido a KB-3 desde la última re-entrada. Si el número supera `umbral_reentrada` en `pipeline_config`, encola un job de re-entrada en Slurm. El umbral es configurable y puede ajustarse entre corridas — alto al principio para evitar re-entradas prematuras, más bajo cuando KB-3 madura.

**Selección de candidatos.** El job consulta `pipeline_document_trace` buscando todos los documentos con `status IN ('blocked_entities', 'provisional')` de cualquier corrida anterior. Los ordena por `n_unmatched DESC` para priorizar los que tienen más probabilidad de desbloquearse con las nuevas entidades. Los documentos cuyo `n_unmatched` original ya era 0 pero eran provisionales por `n_partial` también son candidatos, porque las entidades parciales ahora podrían resolver con match completo.

**Ejecución.** Por cada candidato, el job recupera el `clean_text_url` guardado en `pipeline_document_trace` — que existe siempre porque el PASO 6 lo guarda antes del ruteo en PC-3. Crea un nuevo `run_id` en `pipeline_runs` con un campo `parent_run_id` apuntando al run original. Lanza el job Slurm desde el PASO 6 en adelante, saltando los PASOS 0–5. El texto de entrada es el `clean_text` ya guardado, no hay re-procesamiento de imagen ni re-llamada a Transkribus.

```sql
-- campo adicional en pipeline_runs
ALTER TABLE pipeline.pipeline_runs
  ADD COLUMN parent_run_id UUID REFERENCES pipeline.pipeline_runs(id),
  ADD COLUMN reentry_triggered_by_kb3_count INTEGER;

-- campo adicional en pipeline_document_trace
ALTER TABLE pipeline.pipeline_document_trace
  ADD COLUMN clean_text_url TEXT,
  ADD COLUMN reentry_count INTEGER DEFAULT 0,
  ADD COLUMN last_reentry_run_id UUID;
```

**Resultado esperado por corrida:**

- Corrida 1  KB-3 = solo GT              muchos bloqueados / provisionales
- Corrida 2  KB-3 crece con corrida 1    re-entrada resuelve fracción
- Corrida N  KB-3 madura                 mayoría clean · re-entradas mínimas

Se debe gestionar el riesgo de que un documento re-entre muchas veces sin resolverse. La mitigación es registrar `reentry_count` en `pipeline_document_trace` y establecer un máximo en `pipeline_config`; si se supera, el documento se marca como `requires_manual_review` y sale del ciclo automático.

## Métricas
### Métricas automáticas por punto de control

| Métrica                     | Punto de Control | Umbral alerta (amarillo) | Umbral crítico (rojo)  | Audiencia          |
|:--------------------------- |:---------------- |:------------------------ |:---------------------- |:------------------ |
| CER                         | PC-2, PC-3       | > 5%                     | > 10%                  | CS/ML              |
| WER                         | PC-2, PC-3       | > 15%                    | > 25%                  | CS/ML              |
| Delta CER (HTR → limpio)    | PC-2, PC-3       | Delta negativo           | Delta negativo > 2pp   | CS/ML              |
| BLEU                        | PC-4             | < 60                     | < 50                   | CS/ML + Anotadores |
| ChrF++                      | PC-4             | < 70                     | < 60                   | CS/ML              |
| Compliance de reglas (%)    | PC-4             | < 85% en cualquier regla | < 70% en regla crítica | CS/ML + Anotadores |
| Tasa expansión abreviaturas | PC-3             | < 92%                    | < 85%                  | CS/ML              |
| Entidades protegidas (%)    | PC-3, PC-4       | < 99%                    | < 98%                  | Anotadores         |
| Throughput (docs/hora)      | PC-5             | < 60% del baseline       | < 40% del baseline     | DevOps / CS        |

### Métricas de evaluación - Anotadores

| Dimensión                  | Descripción                             | Escala                     |
|:-------------------------- |:--------------------------------------- |:-------------------------- |
| Fidelidad semántica        | ¿El significado original se preservó?   | 1–5                        |
| Fluidez en español moderno | ¿El texto modernizado suena natural?    | 1–5                        |
| Preservación de entidades  | ¿Nombres, fechas y topónimos correctos? | Binario + lista de errores |
| Adecuación filológica      | ¿Las reglas se aplicaron correctamente? | 1–5 por regla aplicada     |
| Utilidad para NLP          | ¿El texto es apto para tareas NLP?      | 1–3 (baja / media / alta)  |


## Trazabilidad por documento

La tabla `pipeline_document_trace` es el registro central de observabilidad. Se ancla a `Documents.doc_id` y referencia `ML_Models_Key` para identificar exactamente qué modelo produjo cada output.

| Campo                   | Tipo        | Fuente / relación                          |
|:----------------------- |:----------- |:------------------------------------------ |
| `doc_id`                | integer     | FK → `public.Documents(doc_id)`            |
| `run_id`                | uuid        | FK → `pipeline_runs(run_id)`               |
| `histclean_mod_id`      | integer     | FK → `public.ML_Models_Key(Mod_ID)`        |
| `histclean_mod_version` | text        | FK → `public.ML_Models_Key(Model_Version)` |
| `hist2mod_mod_id`       | integer     | FK → `public.ML_Models_Key(Mod_ID)`        |
| `hist2mod_mod_version`  | text        | FK → `public.ML_Models_Key(Model_Version)` |
| `htr_text_url`          | text        | Base de datos: `htr-raw/`                  |
| `heur_text_url`         | text        | Base de datos: `heuristic-cleaned/`        |
| `clean_text_url`        | text        | Base de datos: `clean-text/`               |
| `modern_text_url`       | text        | Base de datos: `modern-text/`              |
| `diff_htr_heur_url`     | text        | Base de datos: `diffs/`                    |
| `diff_heur_clean_url`   | text        | Base de datos: `diffs/`                    |
| `cer_htr`               | real        | Calculado en PC-1 (vs. GT si disponible)   |
| `cer_clean`             | real        | Calculado en PC-3                          |
| `wer_clean`             | real        | Calculado en PC-3                          |
| `bleu_modern`           | real        | Calculado en PC-4                          |
| `chrfpp_modern`         | real        | Calculado en PC-4                          |
| `abbrev_accuracy`       | real        | Calculado en PC-3                          |
| `entity_preservation`   | real        | Calculado en PC-3 y PC-4                   |
| `rules_compliance`      | jsonb       | Resultado por regla filológica (PC-4)      |
| `carril`                | text        | `verde` / `amarillo` / `rojo`              |
| `sha256_modern`         | text        | Hash de integridad del texto final         |
| `created_at`            | timestamptz | Timestamp de procesamiento                 |


## Base de datos

### Relaciones entre tablas existentes y nuevas

```
public.Documents (existente)
    │
    ├──► pipeline_document_trace  (nueva)  ← ancla central de observabilidad
    │         │
    │         ├──► pipeline_runs           (nueva)
    │         └──► public.ML_Models_Key    (existente, sin modificar)
    │
    ├──► pipeline_review_queue    (nueva)
    │         └──► pipeline_document_trace
    │
    └──► pipeline_human_review    (nueva)
              ├──► pipeline_document_trace
              └──► public.Collaborators    (existente, sin modificar)

pipeline_run_metrics              (nueva)
    └──► pipeline_runs

pipeline_config                   (nueva, sin FK — tabla de configuración)
```

### Notas de diseño

- **`ML_Models_Key` no se modifica.** `pipeline_document_trace` referencia `(Mod_ID, Model_Version)` para registrar exactamente qué versión de HistClean-SpA e Hist2Mod-SpA procesó cada documento. La tabla `Model_Use` existente registra uso ad-hoc; `pipeline_document_trace` registra uso en producción con métricas asociadas.
- **`Collaborators` no se modifica.** `pipeline_human_review` usa `collab_ID` como FK para el revisor, manteniendo consistencia con `Document_Reviewers` y `NLP_Annotation`.
- **`NLP_Annotation` no se modifica ni se reemplaza.** Cubre anotaciones NLP generales. `pipeline_human_review` cubre específicamente la revisión de calidad del pipeline (CER, BLEU, fidelidad semántica).
- **`HRT_Status` no se modifica.** Cubre el estado del proceso en Transkribus. `pipeline_document_trace` cubre el estado posterior al HTR.
- **Prefijo `pipeline_`** en todas las tablas nuevas para distinguirlas visualmente del esquema existente.