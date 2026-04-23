-- =============================================================================
-- schema.sql — AmoxcAILab HTR Pipeline
-- =============================================================================
-- DDL idempotente para el schema completo del proyecto.
-- Aplica con: htr_db_schema database/schema.sql
--
-- Schemas:
--   public  — modelo de datos principal (colecciones, documentos, imágenes, HTR, etc.)
--   rag     — base de conocimiento vectorial (abbreviations, entities, error_patterns)
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- EXTENSIONES
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "vector";

-- ---------------------------------------------------------------------------
-- SCHEMA PUBLIC — tablas de catálogo
-- ---------------------------------------------------------------------------

-- Tipos de colección (AGN, AGI, corpus_local, etc.)
CREATE TABLE IF NOT EXISTS public.collection_types (
    collection_type_id   SERIAL PRIMARY KEY,
    collection_type      TEXT NOT NULL UNIQUE
);

-- Estados de una colección
CREATE TABLE IF NOT EXISTS public.collection_statuses (
    collection_status_id SERIAL PRIMARY KEY,
    collection_status    TEXT NOT NULL UNIQUE
);

-- Tipos de documento (expediente, volumen, manuscrito, impreso, etc.)
CREATE TABLE IF NOT EXISTS public.document_types (
    document_type_id     SERIAL PRIMARY KEY,
    document_type        TEXT NOT NULL UNIQUE
);

-- Estados de un documento
CREATE TABLE IF NOT EXISTS public.document_statuses (
    document_status_id   SERIAL PRIMARY KEY,
    document_status      TEXT NOT NULL UNIQUE
);

-- Tipos de imagen (original, processed)
CREATE TABLE IF NOT EXISTS public.image_types (
    image_type_id        SERIAL PRIMARY KEY,
    image_type           TEXT NOT NULL UNIQUE
);

-- Estados de una imagen
CREATE TABLE IF NOT EXISTS public.image_statuses (
    image_status_id      SERIAL PRIMARY KEY,
    image_status         TEXT NOT NULL UNIQUE
);

-- Idiomas
CREATE TABLE IF NOT EXISTS public.languages (
    language_id          SERIAL PRIMARY KEY,
    language             TEXT NOT NULL UNIQUE
);

-- Tipos de caligrafía (procesal, humanística, cortesana, etc.)
CREATE TABLE IF NOT EXISTS public.calligraphy_types (
    calligraphy_type_id  SERIAL PRIMARY KEY,
    calligraphy_type     TEXT NOT NULL UNIQUE
);

-- Tipos de análisis descriptivo
CREATE TABLE IF NOT EXISTS public.analysis_types (
    analysis_type_id     SERIAL PRIMARY KEY,
    analysis_type        TEXT NOT NULL UNIQUE
);

-- Tipos de patrón de error
CREATE TABLE IF NOT EXISTS public.pattern_types (
    pattern_type_id      SERIAL PRIMARY KEY,
    pattern_type         TEXT NOT NULL UNIQUE,
    rules                TEXT
);

-- Tipos de error HTR
CREATE TABLE IF NOT EXISTS public.error_type (
    error_type_id        SERIAL PRIMARY KEY,
    error_type           TEXT NOT NULL UNIQUE
);

-- Tipos de expansión de abreviatura
CREATE TABLE IF NOT EXISTS public.expansion_type (
    expansion_type_id    SERIAL PRIMARY KEY,
    expansion_type       TEXT NOT NULL UNIQUE
);

-- Tipos de operación (reemplaza transaction_types)
CREATE TABLE IF NOT EXISTS public.operation_types (
    operation_type_id    SERIAL PRIMARY KEY,
    operation_type       TEXT NOT NULL UNIQUE,
    description          TEXT,
    entity_scope         TEXT  -- 'collection' | 'document' | 'image' | 'htr' | 'model' | 'system'
);

-- Roles de colaboradores
CREATE TABLE IF NOT EXISTS public.roles (
    role_id              SERIAL PRIMARY KEY,
    role_name            TEXT NOT NULL UNIQUE
);

-- Casos de estudio
CREATE TABLE IF NOT EXISTS public.study_cases (
    study_case_id        SERIAL PRIMARY KEY,
    study_case_name      TEXT NOT NULL UNIQUE
);

-- Tipos de entidad nombrada
CREATE TABLE IF NOT EXISTS public.entity_types (
    entity_type_id       SERIAL PRIMARY KEY,
    entity_type          TEXT NOT NULL UNIQUE
);

-- ---------------------------------------------------------------------------
-- SCHEMA PUBLIC — entidades principales
-- ---------------------------------------------------------------------------

-- Colaboradores (paleógrafos, investigadores, anotadores)
CREATE TABLE IF NOT EXISTS public.collaborators (
    collaborator_id      SERIAL PRIMARY KEY,
    collaborator_name    TEXT NOT NULL UNIQUE
);

-- Colecciones de documentos (AGN/AGI series)
CREATE TABLE IF NOT EXISTS public.collections (
    collection_id        SERIAL PRIMARY KEY,
    collection_name      TEXT NOT NULL,
    collection_path      TEXT,
    collection_type_id   INT REFERENCES public.collection_types(collection_type_id),
    collection_status_id INT REFERENCES public.collection_statuses(collection_status_id),
    collection_url       TEXT,
    metadata_csv_path    TEXT,  -- ruta al archivo nombre_colección_metadata.csv
    collection_detail_1  TEXT,
    collection_detail_n  TEXT
);

-- Documentos (carpetas/expedientes dentro de una colección)
-- Cada documento = una carpeta con páginas (imágenes)
CREATE TABLE IF NOT EXISTS public.documents (
    document_id          SERIAL PRIMARY KEY,
    collection_id        INT REFERENCES public.collections(collection_id),
    document_filename    TEXT NOT NULL,  -- nombre de la carpeta/documento
    document_path        TEXT,
    document_status_id   INT REFERENCES public.document_statuses(document_status_id),
    document_url         TEXT,
    document_detail_1    TEXT,
    document_detail_n    TEXT
);
CREATE INDEX IF NOT EXISTS idx_documents_collection
    ON public.documents(collection_id);

-- Imágenes (páginas individuales de un documento)
-- image_type: 'original' o 'processed'
-- parent_image_id: para imágenes procesadas, referencia a la imagen original
CREATE TABLE IF NOT EXISTS public.images (
    image_id             SERIAL PRIMARY KEY,
    document_id          INT REFERENCES public.documents(document_id),
    parent_image_id      INT REFERENCES public.images(image_id),  -- null para originales
    image_filename       TEXT NOT NULL,
    image_url            TEXT,
    image_path           TEXT,
    language_id          INT REFERENCES public.languages(language_id),
    calligraphy_type_id  INT REFERENCES public.calligraphy_types(calligraphy_type_id),
    image_type_id        INT REFERENCES public.image_types(image_type_id),
    page_number          INT,  -- número de página dentro del documento
    calligraphy_confidence REAL  -- confianza del clasificador tipográfico
);
CREATE INDEX IF NOT EXISTS idx_images_document
    ON public.images(document_id);
CREATE INDEX IF NOT EXISTS idx_images_parent
    ON public.images(parent_image_id);

-- Layouts (resultados del análisis de layout de Transkribus)
CREATE TABLE IF NOT EXISTS public.layouts (
    layout_id            SERIAL PRIMARY KEY,
    image_id             INT REFERENCES public.images(image_id),
    layout_filename      TEXT,
    layout_path          TEXT,    -- ruta al archivo layout_analysis.xml
    transkribus_doc_id   TEXT,    -- ID del documento en Transkribus
    transkribus_page_id  TEXT,    -- ID de la página en Transkribus
    used_processed_image BOOLEAN DEFAULT FALSE  -- indica si se usó imagen procesada
);
CREATE INDEX IF NOT EXISTS idx_layouts_image
    ON public.layouts(image_id);

-- HTR — transcripciones producidas por Transkribus
-- Cada imagen tiene máximo un HTR (registrado automáticamente por trigger_htr_transcription.py)
CREATE TABLE IF NOT EXISTS public.htr (
    htr_id               SERIAL PRIMARY KEY,
    image_id             INT REFERENCES public.images(image_id),
    layout_id            INT REFERENCES public.layouts(layout_id),
    htr_filename         TEXT,
    htr_path             TEXT,    -- data_ingestion/transkribús/collection/document/htr_file.txt
    transkribus_model_id TEXT     -- ID del modelo HTR usado en Transkribus
);
CREATE INDEX IF NOT EXISTS idx_htr_image
    ON public.htr(image_id);

-- Ground truth (referencia de transcripción corregida)
CREATE TABLE IF NOT EXISTS public.ground_truth (
    ground_truth_id      SERIAL PRIMARY KEY,
    htr_id               INT REFERENCES public.htr(htr_id),
    ground_truth_filename TEXT,
    ground_truth_path    TEXT
);

-- Versiones limpias históricas (output de spanish_historical_clean)
CREATE TABLE IF NOT EXISTS public.hist_clean (
    hist_clean_id        SERIAL PRIMARY KEY,
    htr_id               INT REFERENCES public.htr(htr_id),
    hist_clean_filename  TEXT,
    hist_clean_path      TEXT
);

-- Versiones modernizadas (output de spanish_clean_modern)
CREATE TABLE IF NOT EXISTS public.clean_modern (
    clean_modern_id      SERIAL PRIMARY KEY,
    hist_clean_id        INT REFERENCES public.hist_clean(hist_clean_id),
    clean_modern_filename TEXT,
    clean_modern_path    TEXT
);

-- Modelos de ML registrados en el proyecto
CREATE TABLE IF NOT EXISTS public.models (
    model_id             SERIAL PRIMARY KEY,
    model_name           TEXT NOT NULL,
    model_url            TEXT,
    model_local_path     TEXT,  -- ruta en data_ingestion/models/
    model_version        TEXT,
    model_parameter_1    TEXT,
    model_parameter_n    TEXT
);

-- Análisis descriptivos (métricas de calidad con columnas fijas)
CREATE TABLE IF NOT EXISTS public.descriptive_analysis (
    descriptive_analysis_id SERIAL PRIMARY KEY,
    document_id          INT REFERENCES public.documents(document_id),
    htr_id               INT REFERENCES public.htr(htr_id),
    analysis_type_id     INT REFERENCES public.analysis_types(analysis_type_id),
    -- Métricas de calidad NLP
    cer                  REAL,
    wer                  REAL,
    bleu                 REAL,
    chrf_pp              REAL,
    abbrev_accuracy      REAL,
    entity_preservation  REAL,
    rules_compliance_score REAL,
    -- Conteos
    n_errors             INT,
    n_patterns           INT,
    n_corrections        INT,
    -- Trazabilidad del modelo que produjo el análisis
    model_id             INT REFERENCES public.models(model_id),
    analyzed_at          TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_descriptive_analysis_document
    ON public.descriptive_analysis(document_id);
CREATE INDEX IF NOT EXISTS idx_descriptive_analysis_htr
    ON public.descriptive_analysis(htr_id);

-- Patrones de error identificados
CREATE TABLE IF NOT EXISTS public.patterns (
    pattern_id           SERIAL PRIMARY KEY,
    descriptive_analysis_id INT REFERENCES public.descriptive_analysis(descriptive_analysis_id),
    htr                  TEXT,
    ground_truth         TEXT,
    pattern_type_id      INT REFERENCES public.pattern_types(pattern_type_id)
);

-- Errores identificados por análisis descriptivo
CREATE TABLE IF NOT EXISTS public.errors (
    error_id             SERIAL PRIMARY KEY,
    descriptive_analysis_id INT REFERENCES public.descriptive_analysis(descriptive_analysis_id),
    error_type_id        INT REFERENCES public.error_type(error_type_id),
    htr_word             TEXT,
    ground_truth_word    TEXT,
    context              TEXT
);

-- Correcciones propuestas para errores
CREATE TABLE IF NOT EXISTS public.corrections (
    correction_id        SERIAL PRIMARY KEY,
    error_id             INT REFERENCES public.errors(error_id),
    htr_finding          TEXT,
    corrected_word       TEXT,
    score                INT
);

-- Abreviaturas detectadas en documentos históricos
CREATE TABLE IF NOT EXISTS public.abbreviations (
    abbreviation_id      SERIAL PRIMARY KEY,
    image_id             INT REFERENCES public.images(image_id),
    expansion_type_id    INT REFERENCES public.expansion_type(expansion_type_id),
    abbreviation         TEXT NOT NULL
);

-- Expansiones de abreviaturas
CREATE TABLE IF NOT EXISTS public.expansions (
    expansion_id         SERIAL PRIMARY KEY,
    expansion            TEXT NOT NULL
);

-- Entidades nombradas (personas, lugares, instituciones, fechas)
CREATE TABLE IF NOT EXISTS public.entities (
    entity_id            SERIAL PRIMARY KEY,
    entity_name          TEXT NOT NULL,
    canonical_form       TEXT,
    verified             BOOLEAN DEFAULT FALSE
);

-- Notas (comentarios de colaboradores)
CREATE TABLE IF NOT EXISTS public.notes (
    note_id              SERIAL PRIMARY KEY,
    note                 TEXT
);

-- Operaciones (reemplaza transactions) — registro central de todas las acciones
CREATE TABLE IF NOT EXISTS public.operations (
    operation_id         SERIAL PRIMARY KEY,
    operation_type_id    INT REFERENCES public.operation_types(operation_type_id),
    collaborator_id      INT REFERENCES public.collaborators(collaborator_id),
    logged_at            TIMESTAMPTZ DEFAULT NOW(),
    slurm_job_id         TEXT,         -- no nulo solo para jobs GPU en Slurm
    transkribus_job_id   TEXT,         -- no nulo solo para jobs asíncronos de Transkribus
    status               TEXT NOT NULL DEFAULT 'completed'
        CHECK (status IN ('pending', 'running', 'completed', 'failed'))
);
CREATE INDEX IF NOT EXISTS idx_operations_type
    ON public.operations(operation_type_id);
CREATE INDEX IF NOT EXISTS idx_operations_logged_at
    ON public.operations(logged_at);
CREATE INDEX IF NOT EXISTS idx_operations_status
    ON public.operations(status);

-- ---------------------------------------------------------------------------
-- SCHEMA PUBLIC — tablas de unión (n:n)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.documents_document_types (
    document_id          INT REFERENCES public.documents(document_id),
    document_type_id     INT REFERENCES public.document_types(document_type_id),
    PRIMARY KEY (document_id, document_type_id)
);

CREATE TABLE IF NOT EXISTS public.documents_study_cases (
    document_id          INT REFERENCES public.documents(document_id),
    study_case_id        INT REFERENCES public.study_cases(study_case_id),
    PRIMARY KEY (document_id, study_case_id)
);

-- Operaciones sobre colecciones
CREATE TABLE IF NOT EXISTS public.collections_operations (
    collection_id        INT REFERENCES public.collections(collection_id),
    operation_id         INT REFERENCES public.operations(operation_id),
    PRIMARY KEY (collection_id, operation_id)
);

-- Operaciones sobre documentos
CREATE TABLE IF NOT EXISTS public.documents_operations (
    document_id          INT REFERENCES public.documents(document_id),
    operation_id         INT REFERENCES public.operations(operation_id),
    PRIMARY KEY (document_id, operation_id)
);

-- Operaciones sobre imágenes
CREATE TABLE IF NOT EXISTS public.images_operations (
    image_id             INT REFERENCES public.images(image_id),
    operation_id         INT REFERENCES public.operations(operation_id),
    PRIMARY KEY (image_id, operation_id)
);

-- Operaciones sobre HTR
CREATE TABLE IF NOT EXISTS public.htr_operations (
    htr_id               INT REFERENCES public.htr(htr_id),
    operation_id         INT REFERENCES public.operations(operation_id),
    PRIMARY KEY (htr_id, operation_id)
);

-- Operaciones sobre modelos
CREATE TABLE IF NOT EXISTS public.models_operations (
    model_id             INT REFERENCES public.models(model_id),
    operation_id         INT REFERENCES public.operations(operation_id),
    PRIMARY KEY (model_id, operation_id)
);

-- Notas vinculadas a operaciones
CREATE TABLE IF NOT EXISTS public.notes_operation (
    operation_id         INT REFERENCES public.operations(operation_id),
    note_id              INT REFERENCES public.notes(note_id),
    PRIMARY KEY (operation_id, note_id)
);

-- Roles de colaboradores
CREATE TABLE IF NOT EXISTS public.collaborators_roles (
    collaborator_id      INT REFERENCES public.collaborators(collaborator_id),
    role_id              INT REFERENCES public.roles(role_id),
    PRIMARY KEY (collaborator_id, role_id)
);

-- Entidades en transcripciones HTR
CREATE TABLE IF NOT EXISTS public.htr_entities (
    htr_id               INT REFERENCES public.htr(htr_id),
    entity_id            INT REFERENCES public.entities(entity_id),
    PRIMARY KEY (htr_id, entity_id)
);

-- Tipos de cada entidad
CREATE TABLE IF NOT EXISTS public.entities_entity_types (
    entity_id            INT REFERENCES public.entities(entity_id),
    entity_type_id       INT REFERENCES public.entity_types(entity_type_id),
    PRIMARY KEY (entity_id, entity_type_id)
);

-- Abreviaturas en transcripciones HTR
CREATE TABLE IF NOT EXISTS public.htr_abbreviations (
    htr_id               INT REFERENCES public.htr(htr_id),
    abbreviation_id      INT REFERENCES public.abbreviations(abbreviation_id),
    PRIMARY KEY (htr_id, abbreviation_id)
);

-- Expansiones de cada abreviatura
CREATE TABLE IF NOT EXISTS public.abbreviations_expansions (
    abbreviation_id      INT REFERENCES public.abbreviations(abbreviation_id),
    expansion_id         INT REFERENCES public.expansions(expansion_id),
    PRIMARY KEY (abbreviation_id, expansion_id)
);

-- Errores en transcripciones HTR
CREATE TABLE IF NOT EXISTS public.htr_errors (
    htr_id               INT REFERENCES public.htr(htr_id),
    error_id             INT REFERENCES public.errors(error_id),
    PRIMARY KEY (htr_id, error_id)
);

-- Patrones en transcripciones HTR
CREATE TABLE IF NOT EXISTS public.htr_patterns (
    htr_id               INT REFERENCES public.htr(htr_id),
    pattern_id           INT REFERENCES public.patterns(pattern_id),
    PRIMARY KEY (htr_id, pattern_id)
);

-- Estados de imágenes
CREATE TABLE IF NOT EXISTS public.images_image_statuses (
    image_id             INT REFERENCES public.images(image_id),
    image_status_id      INT REFERENCES public.image_statuses(image_status_id),
    PRIMARY KEY (image_id, image_status_id)
);

-- ---------------------------------------------------------------------------
-- SCHEMA RAG — base de conocimiento vectorial
-- ---------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS rag;

CREATE TABLE IF NOT EXISTS rag.knowledge_base (
    knowledge_base_id    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    knowledge_base_type  TEXT NOT NULL
        CHECK (knowledge_base_type IN
            ('abbreviation', 'entity', 'error_pattern', 'document_knowledge')),
    -- Referencias opcionales al schema public
    abbreviation_id      INT REFERENCES public.abbreviations(abbreviation_id),
    expansion_id         INT REFERENCES public.expansions(expansion_id),
    entity_id            INT REFERENCES public.entities(entity_id),
    -- Contenido y embedding
    content              TEXT NOT NULL,
    embedding            VECTOR(768),
    metadata             JSONB,
    verified             BOOLEAN DEFAULT FALSE,
    added_at             TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_knowledge_base_type
    ON rag.knowledge_base(knowledge_base_type);
CREATE INDEX IF NOT EXISTS idx_knowledge_base_verified
    ON rag.knowledge_base(verified);
-- Índice vectorial (se crea después de cargar datos para que sea efectivo)
-- CREATE INDEX IF NOT EXISTS idx_knowledge_base_embedding
--     ON rag.knowledge_base USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);

-- ---------------------------------------------------------------------------
-- DATOS SEMILLA — catálogos
-- ---------------------------------------------------------------------------

-- collection_types
INSERT INTO public.collection_types (collection_type) VALUES
    ('AGN'),
    ('AGI'),
    ('corpus_local'),
    ('ground_truth_collection')
ON CONFLICT (collection_type) DO NOTHING;

-- collection_statuses
INSERT INTO public.collection_statuses (collection_status) VALUES
    ('active'),
    ('archived'),
    ('in_progress')
ON CONFLICT (collection_status) DO NOTHING;

-- document_types
INSERT INTO public.document_types (document_type) VALUES
    ('expediente'),
    ('volumen'),
    ('manuscrito'),
    ('impreso'),
    ('legajo')
ON CONFLICT (document_type) DO NOTHING;

-- document_statuses
INSERT INTO public.document_statuses (document_status) VALUES
    ('new_untouched'),
    ('new_pages_processed'),
    ('new_layout_retrieved'),
    ('new_classified_by_typography'),
    ('new_htr_generated'),
    ('in_cleaning'),
    ('historical_clean_available'),
    ('clean_modern_available'),
    ('to_review'),
    ('reviewed'),
    ('completed')
ON CONFLICT (document_status) DO NOTHING;

-- image_types
INSERT INTO public.image_types (image_type) VALUES
    ('original'),
    ('processed')
ON CONFLICT (image_type) DO NOTHING;

-- image_statuses
INSERT INTO public.image_statuses (image_status) VALUES
    ('registered'),
    ('preprocessed'),
    ('layout_retrieved'),
    ('classified'),
    ('htr_available')
ON CONFLICT (image_status) DO NOTHING;

-- languages
INSERT INTO public.languages (language) VALUES
    ('spanish_early_modern'),
    ('spanish_modern'),
    ('latin'),
    ('nahuatl'),
    ('mixed')
ON CONFLICT (language) DO NOTHING;

-- calligraphy_types
INSERT INTO public.calligraphy_types (calligraphy_type) VALUES
    ('procesal'),
    ('humanistica'),
    ('cortesana'),
    ('gotica'),
    ('italiana'),
    ('mixed'),
    ('unknown')
ON CONFLICT (calligraphy_type) DO NOTHING;

-- analysis_types
INSERT INTO public.analysis_types (analysis_type) VALUES
    ('htr_baseline'),
    ('post_historical_clean'),
    ('post_clean_modern'),
    ('ground_truth_comparison'),
    ('human_review')
ON CONFLICT (analysis_type) DO NOTHING;

-- pattern_types
INSERT INTO public.pattern_types (pattern_type, rules) VALUES
    ('orthographic', 'Variaciones ortográficas históricas predecibles'),
    ('abbreviation', 'Abreviaturas con expansión conocida'),
    ('phonetic', 'Errores fonéticos del OCR/HTR'),
    ('morphological', 'Errores morfológicos en flexión'),
    ('proper_noun', 'Errores en nombres propios')
ON CONFLICT (pattern_type) DO NOTHING;

-- error_type
INSERT INTO public.error_type (error_type) VALUES
    ('substitution'),
    ('insertion'),
    ('deletion'),
    ('transposition'),
    ('word_boundary'),
    ('abbreviation_unresolved'),
    ('entity_unrecognized')
ON CONFLICT (error_type) DO NOTHING;

-- expansion_type
INSERT INTO public.expansion_type (expansion_type) VALUES
    ('certain'),
    ('probable'),
    ('uncertain'),
    ('contextual')
ON CONFLICT (expansion_type) DO NOTHING;

-- roles
INSERT INTO public.roles (role_name) VALUES
    ('paleographer'),
    ('researcher'),
    ('annotator'),
    ('developer'),
    ('ml_engineer'),
    ('project_lead')
ON CONFLICT (role_name) DO NOTHING;

-- entity_types
INSERT INTO public.entity_types (entity_type) VALUES
    ('person'),
    ('place'),
    ('institution'),
    ('date'),
    ('ship'),
    ('cargo'),
    ('currency'),
    ('office')
ON CONFLICT (entity_type) DO NOTHING;

-- operation_types — catálogo completo de todas las acciones del pipeline
INSERT INTO public.operation_types (operation_type, description, entity_scope) VALUES
    -- Ingesta
    ('collection_registered',       'Metadatos de colección registrados en BD', 'collection'),
    ('document_registered',         'Subdirectorio registrado como documento', 'document'),
    ('images_downloaded',           'Imágenes descargadas desde fuente externa', 'collection'),
    ('image_registered',            'Imagen (página) registrada en BD', 'image'),
    -- Preprocesamiento
    ('image_preprocessed',          'Ecualización de histograma aplicada', 'image'),
    -- Transkribus
    ('layout_retrieved',            'Layout XML obtenido de Transkribus (asíncrono)', 'image'),
    ('typography_classified',       'Tipo de caligrafía asignado', 'image'),
    ('htr_available',               'HTR generado y almacenado localmente', 'htr'),
    -- Limpieza
    ('htr_cleaning_started',        'Proceso de limpieza histórica iniciado', 'htr'),
    ('htr_cleaning_completed',      'Limpieza histórica completada', 'htr'),
    ('historical_clean_available',  'Versión histórica limpia disponible (spanish_historical_clean)', 'htr'),
    ('clean_modern_available',      'Versión modernizada disponible (spanish_clean_modern)', 'htr'),
    -- Revisión y análisis
    ('descriptive_analysis_computed', 'Análisis descriptivo calculado y registrado', 'document'),
    ('document_to_review',          'Documento encolado para revisión humana', 'document'),
    ('document_reviewed',           'Revisión humana completada', 'document'),
    -- Ground truth
    ('ground_truth_registered',     'Archivo ground_truth vinculado a HTR', 'htr'),
    -- Modelos
    ('model_registered',            'Modelo de ML registrado en BD', 'model'),
    ('model_evaluated',             'Modelo evaluado contra conjunto de prueba', 'model'),
    ('model_deployed',              'Modelo marcado como activo para el pipeline', 'model'),
    -- Anotación y base de conocimiento
    ('entity_verified',             'Entidad verificada por paleógrafo', 'system'),
    ('correction_applied',          'Corrección de error aplicada', 'system'),
    ('expansion_added',             'Expansión de abreviatura añadida', 'system'),
    ('abbreviation_resolved',       'Abreviatura resuelta en contexto', 'system'),
    ('annotation_synced',           'Archivo JSON de anotación importado desde GitHub', 'system'),
    ('knowledge_base_rebuilt',      'Base de conocimiento RAG reconstruida', 'system'),
    -- Sistema
    ('annotation_export_generated', 'JSON de estado exportado para aplicación de anotación', 'system'),
    ('db_backup_created',           'Backup de PostgreSQL creado', 'system'),
    ('schema_migrated',             'Schema SQL aplicado o actualizado', 'system')
ON CONFLICT (operation_type) DO NOTHING;

-- ---------------------------------------------------------------------------
-- VISTAS DE OBSERVABILIDAD
-- ---------------------------------------------------------------------------

-- Estado actual del pipeline por documento
-- Muestra la última operación completada sobre cada documento
CREATE OR REPLACE VIEW public.v_pipeline_status AS
SELECT
    d.document_id,
    d.document_filename,
    c.collection_name,
    ds.document_status,
    ot.operation_type AS last_operation,
    o.logged_at        AS last_operation_at
FROM public.documents d
JOIN public.collections c ON d.collection_id = c.collection_id
LEFT JOIN public.document_statuses ds ON d.document_status_id = ds.document_status_id
LEFT JOIN public.documents_operations dop ON d.document_id = dop.document_id
LEFT JOIN public.operations o ON dop.operation_id = o.operation_id
LEFT JOIN public.operation_types ot ON o.operation_type_id = ot.operation_type_id
WHERE o.logged_at = (
    SELECT MAX(o2.logged_at)
    FROM public.documents_operations dop2
    JOIN public.operations o2 ON dop2.operation_id = o2.operation_id
    WHERE dop2.document_id = d.document_id
      AND o2.status = 'completed'
);

-- Documentos pendientes de cada etapa
CREATE OR REPLACE VIEW public.v_pipeline_pending AS
SELECT
    ot_target.operation_type AS pending_operation,
    COUNT(DISTINCT d.document_id) AS n_documents
FROM public.documents d
CROSS JOIN public.operation_types ot_target
WHERE NOT EXISTS (
    SELECT 1
    FROM public.documents_operations dop
    JOIN public.operations o ON dop.operation_id = o.operation_id
    JOIN public.operation_types ot ON o.operation_type_id = ot.operation_type_id
    WHERE dop.document_id = d.document_id
      AND ot.operation_type = ot_target.operation_type
      AND o.status = 'completed'
)
AND ot_target.entity_scope IN ('document', 'htr')
GROUP BY ot_target.operation_type
ORDER BY ot_target.operation_type_id;

-- Métricas de calidad por colección (última corrida de análisis)
CREATE OR REPLACE VIEW public.v_quality_metrics AS
SELECT
    c.collection_name,
    at2.analysis_type,
    ROUND(AVG(da.cer)::NUMERIC, 4)                AS avg_cer,
    ROUND(AVG(da.wer)::NUMERIC, 4)                AS avg_wer,
    ROUND(AVG(da.bleu)::NUMERIC, 2)               AS avg_bleu,
    ROUND(AVG(da.entity_preservation)::NUMERIC, 4) AS avg_entity_preservation,
    COUNT(da.descriptive_analysis_id)              AS n_analyses
FROM public.descriptive_analysis da
JOIN public.documents d ON da.document_id = d.document_id
JOIN public.collections c ON d.collection_id = c.collection_id
JOIN public.analysis_types at2 ON da.analysis_type_id = at2.analysis_type_id
GROUP BY c.collection_name, at2.analysis_type;

COMMIT;
