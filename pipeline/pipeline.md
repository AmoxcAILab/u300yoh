# Pipeline de procesamiento — AmoxcAILab

El flujo de procesamiento sucede en 6 capas de abstracción: `infrastructure`, `database`,
`data_ingestion`, `pipeline`, `visualization` y `outputs`. Cada una está representada con
una carpeta en el repositorio, que contiene todos los scripts y archivos intermedios según
su utilidad y propósito.

---

## Principio de observabilidad: todo es una operación

Toda acción sobre cualquier entidad del sistema queda registrada como una fila en
`public.operations` + un registro en la tabla de unión correspondiente a la entidad
afectada (`collections_operations`, `documents_operations`, `images_operations`,
`htr_operations`, `models_operations`).

No hay tablas de observabilidad separadas. El estado del pipeline se consulta filtrando
operaciones por tipo y entidad.

---

## Catálogo de tipos de operación

| `operation_type` | Entidad | Asíncrona | Genera `descriptive_analysis` | Script |
|---|---|---|---|---|
| `collection_registered` | collection | — | — | `register_collection.py` |
| `document_registered` | document | — | — | `register_collection.py` |
| `images_downloaded` | collection | — | — | `import_collection.py` |
| `image_registered` | image | — | — | `register_collection.py` / `import_collection.py` |
| `image_preprocessed` | image | — | — | `image_pre_processing.py` |
| `layout_retrieved` | image | Sí (transkribus_job_id) | — | `send_to_layout_analysis.py` |
| `typography_classified` | image | Slurm | — | `typography_classification.py` |
| `htr_available` | htr | Sí (transkribus_job_id) | — | `trigger_htr_transcription.py` |
| `htr_cleaning_started` | htr | Slurm | — | `job_historical_clean.sh` |
| `htr_cleaning_completed` | htr | Slurm | Sí (post_historical_clean) | `job_historical_clean.sh` |
| `historical_clean_available` | htr | Slurm | — | `job_historical_clean.sh` |
| `clean_modern_available` | htr | Slurm | Sí (post_clean_modern) | `job_clean_modern.sh` |
| `ground_truth_registered` | htr | — | — | `register_ground_truth.py` |
| `descriptive_analysis_computed` | document | — | Sí | pipeline scripts |
| `document_to_review` | document | — | — | pipeline scripts |
| `document_reviewed` | document | — | — | anotadores |
| `model_registered` | model | — | — | `htr_register_model` |
| `model_evaluated` | model | Slurm | — | jobs de evaluación |
| `model_deployed` | model | — | — | `htr_register_model` |
| `entity_verified` | system | — | — | sync de anotaciones |
| `correction_applied` | system | — | — | sync de anotaciones |
| `expansion_added` | system | — | — | sync de anotaciones |
| `abbreviation_resolved` | system | — | — | sync de anotaciones |
| `annotation_synced` | system | — | — | `sync_annotations.py` |
| `knowledge_base_rebuilt` | system | — | — | `build_knowledge_base.py` |
| `annotation_export_generated` | system | — | — | `export_for_annotation.py` |
| `db_backup_created` | system | — | — | `create_backup.py` |
| `schema_migrated` | system | — | — | `htr_db_schema` |

---

## Flujo del pipeline como secuencia de operaciones

### PASO 0 — Registro de colección

**Script:** `data_ingestion/register_collection.py`
**Operaciones:** `collection_registered` → `document_registered` × N → `image_registered` × M

Estructura de directorios esperada en `--source-dir`:
```
nombre_colección/
  nombre_colección_metadata.csv   ← metadatos de todos los documentos
  documento_001/                  ← cada subdirectorio = un documento
    imagen_001.jpg                ← cada imagen = una página del documento
    imagen_002.jpg
  documento_002/
    ...
```

El CSV de metadatos informa el proceso de etiquetado dentro de la base de datos.
La colección se registra en `public.collections`, cada subdirectorio en
`public.documents`, y cada imagen en `public.images`.

### PASO 0b — Descarga de imágenes (alternativa)

**Script:** `data_ingestion/import_collection.py`
**Operaciones:** `images_downloaded` + `image_registered` × N

Descarga imágenes desde una fuente externa (AGN, AGI, Google Drive) a
`data_ingestion/raw_collections_images/collection_name/`.

### PASO 1 — Preprocesamiento de imágenes

**Script:** `data_ingestion/image_pre_processing.py`
**Operaciones:** `image_preprocessed` por imagen
**Estado de documento:** `new_pages_processed`

Aplica ecualización de histograma para aumentar el contraste. Guarda la imagen
procesada en la misma carpeta de la original. La imagen procesada se registra con
`image_type='processed'` y `parent_image_id` apuntando a la imagen original.

Existen dos caminos para pasos posteriores: usar imágenes originales o procesadas.

### PASO 2 — Layout analysis (Transkribus)

**Script:** `data_ingestion/send_to_layout_analysis.py`
**Operaciones:** `layout_retrieved` (asíncrona, `transkribus_job_id`)
**Estado de documento:** `new_layout_retrieved`

Llama a la API de Transkribus para registrar la colección, documentos e imágenes.
El resultado es un archivo `layout_analysis.xml` por imagen, guardado en
`data_ingestion/transkribús/collection_name/document_name/`.

La operación registra `transkribus_job_id` con `status='running'`. Al completarse
Transkribus, el script actualiza a `status='completed'`.

La bandera `used_processed_image` en `public.layouts` indica si se usó la imagen
original o la versión procesada.

### PASO 3 — Clasificación tipográfica (GPU Slurm)

**Script:** `data_ingestion/typography_classification.py`
**Job Slurm:** `infrastructure/slurm/job_typography_classification.sh`
**Operaciones:** `typography_classified` por imagen
**Estado de documento:** `new_classified_by_typography`

Toma las imágenes procesadas y los archivos XML de layout como entrada.
El modelo clasificador vive en `data_ingestion/models/` (descargado de HuggingFace).

**Para ejecutar el modelo local:**
```bash
# Descargar modelo a la carpeta de modelos locales
htr_register_model --name typography_classifier --model-url <URL_HUGGINGFACE> --local

# Registrar en BD
htr_register_model --name typography_classifier --version 1.0

# Ejecutar clasificación vía Slurm
htr_slurm_typography_classification
```

Registra `calligraphy_type` y `calligraphy_confidence` en `public.images`.

### PASO 4 — Transcripción HTR (Transkribus, GPU Slurm)

**Script:** `data_ingestion/trigger_htr_transcription.py`
**Job Slurm:** `infrastructure/slurm/job_htr_transcription.sh`
**Operaciones:** `htr_available` (asíncrona, `transkribus_job_id`)
**Estado de documento:** `new_htr_generated`

Retoma el flujo de Transkribus usando el `transkribus_job_id` del layout,
selecciona el modelo HTR acorde al tipo de caligrafía detectado en PASO 3, y
solicita la transcripción.

Los archivos HTR se guardan en:
```
data_ingestion/transkribús/
  collection_name/
    document_name/
      imagen_001_htr.txt
      imagen_002_htr.txt
```

Cada archivo HTR se registra en `public.htr` con su `htr_path` y `transkribus_model_id`.

### PASO 5 — Limpieza histórica (GPU Slurm)

**Job Slurm:** `infrastructure/slurm/job_historical_clean.sh`
**Modelo:** `spanish_historical_clean`
**Operaciones:** `htr_cleaning_started` → `htr_cleaning_completed` + `descriptive_analysis_computed` → `historical_clean_available`

Ejecuta el modelo `spanish_historical_clean` sobre los archivos HTR.
Registra métricas CER, WER, `abbrev_accuracy`, `entity_preservation` en
`public.descriptive_analysis` con `analysis_type='post_historical_clean'`.

### PASO 6 — Modernización (GPU Slurm)

**Job Slurm:** `infrastructure/slurm/job_clean_modern.sh`
**Modelo:** `spanish_clean_modern`
**Operaciones:** `clean_modern_available` + `descriptive_analysis_computed`

Ejecuta `spanish_clean_modern` sobre los archivos de `hist_clean`.
Registra métricas BLEU, ChrF++, `rules_compliance_score`, `entity_preservation` en
`public.descriptive_analysis` con `analysis_type='post_clean_modern'`.

### PASO 7 — Revisión humana

**Operaciones:** `document_to_review` → `document_reviewed`

Documentos con métricas fuera de umbral se marcan `document_to_review` y son
exportados para la aplicación de anotación. Los paleógrafos los revisan y la
operación `document_reviewed` cierra el ciclo.

### PASO 0M — Ground truth (migración)

**Script:** `data_ingestion/register_ground_truth.py`
**Operaciones:** `ground_truth_registered` por HTR

Script de migración que asume colecciones importadas y HTR generados.
Recorre `data_ingestion/ground_truth/`, que contiene una carpeta por documento.
Compara el nombre de cada carpeta con los documentos en BD, identifica el `document_id`,
y parear cada archivo `.txt` con el `htr_id` correspondiente por nombre de archivo.

---

## Flujo de anotaciones: GitHub ↔ BD

### Exportación (BD → JSON para paleógrafos)

**Comando:** `htr_export_for_annotation --collection-id INT [--output-dir DIR]`
**Operación:** `annotation_export_generated`

Genera JSONs con el estado actual para que la aplicación de anotación trabaje
con información actualizada:
- `collection_{id}_documents.json` — documentos, imágenes, estado HTR
- `collection_{id}_abbreviations.json` — abreviaturas existentes y sus expansiones
- `collection_{id}_entities.json` — entidades con estado de verificación
- `collection_{id}_errors.json` — errores y correcciones

### Importación (JSON → BD desde GitHub)

**Comando:** `htr_sync_annotations [--annotations-dir DIR]`
**Operación:** `annotation_synced` por JSON procesado

Flujo:
1. `git pull` del directorio de anotaciones
2. Detecta JSONs nuevos/modificados por SHA-256
3. Inserta/actualiza: `abbreviations`, `expansions`, `errors`, `corrections`,
   `patterns`, `entities`, `descriptive_analysis`
4. `collaborator_id` tomado del JSON (seleccionado en la aplicación de anotación)
5. Llama `htr_knowledge_base_rebuild` automáticamente

### Formato de archivos de anotación JSON

Los archivos de anotación generados por la aplicación siguen este esquema:

```json
{
  "collaborator_id": 3,
  "collection_id": 42,
  "exported_at": "2026-04-21T10:00:00Z",
  "abbreviations": [
    {
      "abbreviation_id": null,
      "abbreviation": "dho",
      "expansion_type": "certain",
      "expansions": ["dicho"]
    }
  ],
  "entities": [
    {
      "entity_id": null,
      "entity_name": "Nueva España",
      "entity_type": "place",
      "canonical_form": "Nueva España",
      "verified": true
    }
  ],
  "errors": [
    {
      "htr_id": 100,
      "htr_word": "flotta",
      "ground_truth_word": "flota",
      "error_type": "substitution",
      "corrections": [
        {"corrected_word": "flota", "score": 5}
      ]
    }
  ]
}
```

---

## Queries de observabilidad estándar

```sql
-- 1. Estado del pipeline por documento en una colección
SELECT document_filename, last_operation, last_operation_at
FROM public.v_pipeline_status
WHERE collection_name = 'AGN_Flotas_Serie_1';

-- 2. Imágenes con layout_retrieved pero sin typography_classified
SELECT i.image_id, i.image_filename
FROM public.images i
JOIN public.images_operations io1 ON i.image_id = io1.image_id
JOIN public.operations o1 ON io1.operation_id = o1.operation_id
JOIN public.operation_types ot1 ON o1.operation_type_id = ot1.operation_type_id
WHERE ot1.operation_type = 'layout_retrieved'
  AND o1.status = 'completed'
  AND NOT EXISTS (
      SELECT 1
      FROM public.images_operations io2
      JOIN public.operations o2 ON io2.operation_id = o2.operation_id
      JOIN public.operation_types ot2 ON o2.operation_type_id = ot2.operation_type_id
      WHERE io2.image_id = i.image_id
        AND ot2.operation_type = 'typography_classified'
        AND o2.status = 'completed'
  );

-- 3. HTR disponibles pendientes de limpieza
SELECT h.htr_id, h.htr_path
FROM public.htr h
JOIN public.htr_operations ho1 ON h.htr_id = ho1.htr_id
JOIN public.operations o1 ON ho1.operation_id = o1.operation_id
JOIN public.operation_types ot1 ON o1.operation_type_id = ot1.operation_type_id
WHERE ot1.operation_type = 'htr_available'
  AND o1.status = 'completed'
  AND NOT EXISTS (
      SELECT 1
      FROM public.htr_operations ho2
      JOIN public.operations o2 ON ho2.operation_id = o2.operation_id
      JOIN public.operation_types ot2 ON o2.operation_type_id = ot2.operation_type_id
      WHERE ho2.htr_id = h.htr_id
        AND ot2.operation_type = 'htr_cleaning_started'
  );

-- 4. Documentos en revisión por colaborador
SELECT d.document_filename, c.collaborator_name, o.logged_at
FROM public.documents d
JOIN public.documents_operations dop ON d.document_id = dop.document_id
JOIN public.operations o ON dop.operation_id = o.operation_id
JOIN public.operation_types ot ON o.operation_type_id = ot.operation_type_id
JOIN public.collaborators c ON o.collaborator_id = c.collaborator_id
WHERE ot.operation_type = 'document_to_review'
ORDER BY c.collaborator_name, o.logged_at;

-- 5. Tasa de completitud por colección
SELECT
    col.collection_name,
    COUNT(DISTINCT d.document_id)  AS total_documents,
    COUNT(DISTINCT CASE WHEN vs.last_operation = 'clean_modern_available'
                        THEN d.document_id END) AS completed,
    ROUND(100.0 * COUNT(DISTINCT CASE WHEN vs.last_operation = 'clean_modern_available'
                                      THEN d.document_id END)
          / NULLIF(COUNT(DISTINCT d.document_id), 0), 1) AS pct_complete
FROM public.documents d
JOIN public.collections col ON d.collection_id = col.collection_id
LEFT JOIN public.v_pipeline_status vs ON d.document_id = vs.document_id
GROUP BY col.collection_name;

-- 6. Métricas de calidad promedio por colección
SELECT * FROM public.v_quality_metrics
ORDER BY collection_name, analysis_type;

-- 7. Jobs de Slurm activos o fallidos
SELECT o.operation_id, ot.operation_type, o.slurm_job_id, o.status, o.logged_at
FROM public.operations o
JOIN public.operation_types ot ON o.operation_type_id = ot.operation_type_id
WHERE o.slurm_job_id IS NOT NULL
  AND o.status IN ('running', 'failed')
ORDER BY o.logged_at DESC;
```

---

## Métricas de calidad — columnas de `descriptive_analysis`

| Columna | Descripción | Punto del pipeline |
|---|---|---|
| `cer` | Character Error Rate | post_historical_clean |
| `wer` | Word Error Rate | post_historical_clean |
| `bleu` | BLEU score | post_clean_modern |
| `chrf_pp` | ChrF++ score | post_clean_modern |
| `abbrev_accuracy` | Tasa de expansión correcta de abreviaturas | post_historical_clean |
| `entity_preservation` | Proporción de entidades preservadas | post_historical_clean, post_clean_modern |
| `rules_compliance_score` | Score de cumplimiento de reglas filológicas (~25 reglas) | post_clean_modern |
| `n_errors` | Número de errores detectados | cualquier análisis |
| `n_patterns` | Número de patrones identificados | cualquier análisis |
| `n_corrections` | Número de correcciones aplicadas | cualquier análisis |

Los análisis generados por `pipeline/htr_descriptive_analysis/` alimentan
`n_errors` y `n_patterns` a través de sus scripts de reporte. Ver
`pipeline/htr_descriptive_analysis/htr_descriptive_analysis.md` para la
documentación completa de ese subsistema.
