-- =============================================================================
-- schema.sql — AmoxcAILab HTR Pipeline
-- =============================================================================
-- DDL idempotente para el schema completo del proyecto.
-- Aplica con: htr_db_schema database/schema.sql
--
-- Schemas:
--   public  — modelo de datos principal (colecciones, documentos, imágenes, HTR, etc.)
--   rag     — base de conocimiento vectorial (abbreviations, entities, error_patterns)
--
-- PKs: UUID en todas las tablas (gen_random_uuid(), built-in PostgreSQL 13+)
-- RAG schema ya usa UUID — no se toca.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- MIGRACIONES (idempotentes — se aplican antes que el DDL principal)
-- ---------------------------------------------------------------------------
-- notes_operation → notes_operations
DO $$ BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'notes_operation'
  ) THEN
    ALTER TABLE public.notes_operation RENAME TO notes_operations;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- EXTENSIONES
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS "vector";

-- ---------------------------------------------------------------------------
-- SCHEMA PUBLIC — tablas de catálogo / lookup
-- ---------------------------------------------------------------------------

-- Tipos de colección (AGN, AMP, BP, AGI, corpus_local, etc.)
CREATE TABLE IF NOT EXISTS public.collection_types (
    collection_type_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    collection_type      TEXT NOT NULL UNIQUE
);

-- Estados de una colección
CREATE TABLE IF NOT EXISTS public.collection_statuses (
    collection_status_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    collection_status    TEXT NOT NULL UNIQUE
);

-- Instituciones archivísticas
CREATE TABLE IF NOT EXISTS public.archival_institutions (
    archival_institution_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    archival_institution_name TEXT NOT NULL UNIQUE,
    archival_institution_short TEXT UNIQUE  -- sigla: AGN, AMP, BP, AGI
);

-- Tipos de documento
CREATE TABLE IF NOT EXISTS public.document_types (
    document_type_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    document_type        TEXT NOT NULL UNIQUE
);

-- Estados de un documento
CREATE TABLE IF NOT EXISTS public.document_statuses (
    document_status_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    document_status      TEXT NOT NULL UNIQUE
);

-- Tipos de imagen (original, processed)
CREATE TABLE IF NOT EXISTS public.image_types (
    image_type_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    image_type           TEXT NOT NULL UNIQUE
);

-- Estados de una imagen
CREATE TABLE IF NOT EXISTS public.image_statuses (
    image_status_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    image_status         TEXT NOT NULL UNIQUE
);

-- Idiomas
CREATE TABLE IF NOT EXISTS public.languages (
    language_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    language             TEXT NOT NULL UNIQUE
);

-- Tipos de caligrafía (procesal, humanística, cortesana, etc.)
CREATE TABLE IF NOT EXISTS public.calligraphy_types (
    calligraphy_type_id  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    calligraphy_type     TEXT NOT NULL UNIQUE
);

-- Tipos de análisis descriptivo
CREATE TABLE IF NOT EXISTS public.analysis_types (
    analysis_type_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    analysis_type        TEXT NOT NULL UNIQUE
);

-- Tipos de patrón de error
CREATE TABLE IF NOT EXISTS public.pattern_types (
    pattern_type_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    pattern_type         TEXT NOT NULL UNIQUE,
    rules                TEXT
);

-- Tipos de error HTR
CREATE TABLE IF NOT EXISTS public.error_type (
    error_type_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    error_type           TEXT NOT NULL UNIQUE
);

-- Tipos de expansión de abreviatura
CREATE TABLE IF NOT EXISTS public.expansion_type (
    expansion_type_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    expansion_type       TEXT NOT NULL UNIQUE
);

-- Tipos de operación
CREATE TABLE IF NOT EXISTS public.operation_types (
    operation_type_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    operation_type       TEXT NOT NULL UNIQUE,
    description          TEXT,
    entity_scope         TEXT
);

-- Roles de colaboradores
CREATE TABLE IF NOT EXISTS public.roles (
    role_id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    role_name            TEXT NOT NULL UNIQUE
);

-- Casos de estudio
CREATE TABLE IF NOT EXISTS public.study_cases (
    study_case_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    study_case_name      TEXT NOT NULL UNIQUE
);

-- Tipos de entidad nombrada
CREATE TABLE IF NOT EXISTS public.entity_types (
    entity_type_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_type          TEXT NOT NULL UNIQUE
);

-- ---------------------------------------------------------------------------
-- SCHEMA PUBLIC — entidades principales
-- ---------------------------------------------------------------------------

-- Colaboradores (paleógrafos, investigadores, anotadores)
CREATE TABLE IF NOT EXISTS public.collaborators (
    collaborator_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    collaborator_name    TEXT NOT NULL UNIQUE
);

-- Colecciones de documentos
CREATE TABLE IF NOT EXISTS public.collections (
    collection_id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    collection_name             TEXT NOT NULL,
    collection_path             TEXT,
    collection_type_id          UUID REFERENCES public.collection_types(collection_type_id),
    collection_status_id        UUID REFERENCES public.collection_statuses(collection_status_id),
    collection_url              TEXT,
    archival_institution_id     UUID REFERENCES public.archival_institutions(archival_institution_id)
);

-- Documentos (expedientes/volúmenes dentro de una colección)
-- Campos archivísticos explícitos para los 4 tipos de colección iniciales.
-- Campos desconocidos en .metadata se añaden dinámicamente con ALTER TABLE ADD COLUMN IF NOT EXISTS.
CREATE TABLE IF NOT EXISTS public.documents (
    document_id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    collection_id             UUID NOT NULL REFERENCES public.collections(collection_id),
    document_status_id        UUID REFERENCES public.document_statuses(document_status_id),
    document_name             TEXT NOT NULL,
    document_path             TEXT,
    document_url              TEXT,
    -- Campos archivísticos comunes a todos los tipos de colección
    document_archive          TEXT,
    -- AGN / AMP / BP
    document_Fondo            TEXT,
    document_Volumen          TEXT,
    -- AGN
    document_Caja             TEXT,
    -- AMP
    document_Tomo             TEXT,
    document_Documento        TEXT,
    -- AGN / AMP
    document_Legajo           TEXT,
    -- AGN / BP
    document_Expediente       TEXT,
    -- AGI
    document_Titulo           TEXT,
    document_Signatura        TEXT,
    document_Productores      TEXT,
    document_Indices_de_Descripcion TEXT,
    -- Todos los tipos
    document_Fecha_creacion   TEXT,
    document_Año_creacion     TEXT,
    document_Lugar_creacion   TEXT,
    document_Soporte          TEXT,
    document_Descripcion      TEXT,
    document_Rango_fojas      TEXT,
    document_Num_pags         TEXT,
    document_Num_pags_escritas TEXT
);
CREATE INDEX IF NOT EXISTS idx_documents_collection
    ON public.documents(collection_id);

-- Imágenes (páginas individuales de un documento)
CREATE TABLE IF NOT EXISTS public.images (
    image_id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    document_id          UUID NOT NULL REFERENCES public.documents(document_id),
    parent_image_id      UUID REFERENCES public.images(image_id),
    image_filename       TEXT NOT NULL,
    image_url            TEXT,
    image_path           TEXT,
    language_id          UUID REFERENCES public.languages(language_id),
    calligraphy_type_id  UUID REFERENCES public.calligraphy_types(calligraphy_type_id),
    image_type_id        UUID REFERENCES public.image_types(image_type_id),
    page_number          INT,
    calligraphy_confidence REAL
);
CREATE INDEX IF NOT EXISTS idx_images_document
    ON public.images(document_id);
CREATE INDEX IF NOT EXISTS idx_images_parent
    ON public.images(parent_image_id);

-- Layouts (análisis de layout de Transkribus)
CREATE TABLE IF NOT EXISTS public.layouts (
    layout_id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    image_id             UUID REFERENCES public.images(image_id),
    layout_filename      TEXT,
    layout_path          TEXT,
    transkribus_doc_id   TEXT,
    transkribus_page_id  TEXT,
    used_processed_image BOOLEAN DEFAULT FALSE
);
CREATE INDEX IF NOT EXISTS idx_layouts_image
    ON public.layouts(image_id);

-- HTR — transcripciones producidas por Transkribus
CREATE TABLE IF NOT EXISTS public.htr (
    htr_id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    image_id             UUID REFERENCES public.images(image_id),
    layout_id            UUID REFERENCES public.layouts(layout_id),
    htr_filename         TEXT,
    htr_path             TEXT,
    transkribus_model_id TEXT
);
CREATE INDEX IF NOT EXISTS idx_htr_image
    ON public.htr(image_id);

-- Ground truth
CREATE TABLE IF NOT EXISTS public.ground_truth (
    ground_truth_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    htr_id               UUID REFERENCES public.htr(htr_id),
    ground_truth_filename TEXT,
    ground_truth_path    TEXT
);

-- Versiones limpias históricas
CREATE TABLE IF NOT EXISTS public.hist_clean (
    hist_clean_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    htr_id               UUID REFERENCES public.htr(htr_id),
    hist_clean_filename  TEXT,
    hist_clean_path      TEXT
);

-- Versiones modernizadas
CREATE TABLE IF NOT EXISTS public.clean_modern (
    clean_modern_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    hist_clean_id        UUID REFERENCES public.hist_clean(hist_clean_id),
    clean_modern_filename TEXT,
    clean_modern_path    TEXT
);

-- Modelos de ML
CREATE TABLE IF NOT EXISTS public.models (
    model_id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    model_name           TEXT NOT NULL,
    model_url            TEXT,
    model_local_path     TEXT,
    model_version        TEXT,
    model_parameter_1    TEXT,
    model_parameter_n    TEXT
);

-- Análisis descriptivos
CREATE TABLE IF NOT EXISTS public.descriptive_analysis (
    descriptive_analysis_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    document_id          UUID REFERENCES public.documents(document_id),
    htr_id               UUID REFERENCES public.htr(htr_id),
    analysis_type_id     UUID REFERENCES public.analysis_types(analysis_type_id),
    cer                  REAL,
    wer                  REAL,
    bleu                 REAL,
    chrf_pp              REAL,
    abbrev_accuracy      REAL,
    entity_preservation  REAL,
    rules_compliance_score REAL,
    n_errors             INT,
    n_patterns           INT,
    n_corrections        INT,
    model_id             UUID REFERENCES public.models(model_id),
    analyzed_at          TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_descriptive_analysis_document
    ON public.descriptive_analysis(document_id);
CREATE INDEX IF NOT EXISTS idx_descriptive_analysis_htr
    ON public.descriptive_analysis(htr_id);

-- Patrones de error
CREATE TABLE IF NOT EXISTS public.patterns (
    pattern_id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    descriptive_analysis_id UUID REFERENCES public.descriptive_analysis(descriptive_analysis_id),
    htr                  TEXT,
    ground_truth         TEXT,
    pattern_type_id      UUID REFERENCES public.pattern_types(pattern_type_id)
);

-- Errores HTR
CREATE TABLE IF NOT EXISTS public.errors (
    error_id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    descriptive_analysis_id UUID REFERENCES public.descriptive_analysis(descriptive_analysis_id),
    error_type_id        UUID REFERENCES public.error_type(error_type_id),
    htr_word             TEXT,
    ground_truth_word    TEXT,
    context              TEXT
);

-- Correcciones propuestas
CREATE TABLE IF NOT EXISTS public.corrections (
    correction_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    error_id             UUID REFERENCES public.errors(error_id),
    htr_finding          TEXT,
    corrected_word       TEXT,
    score                INT
);

-- Abreviaturas
CREATE TABLE IF NOT EXISTS public.abbreviations (
    abbreviation_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    image_id             UUID REFERENCES public.images(image_id),
    expansion_type_id    UUID REFERENCES public.expansion_type(expansion_type_id),
    abbreviation         TEXT NOT NULL
);

-- Expansiones de abreviaturas
CREATE TABLE IF NOT EXISTS public.expansions (
    expansion_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    expansion            TEXT NOT NULL
);

-- Entidades nombradas
CREATE TABLE IF NOT EXISTS public.entities (
    entity_id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_name          TEXT NOT NULL,
    canonical_form       TEXT,
    verified             BOOLEAN DEFAULT FALSE
);

-- Notas — entidad independiente que extiende la descripción de otras entidades
CREATE TABLE IF NOT EXISTS public.notes (
    note_id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    note                 TEXT
);

-- Operaciones — registro central de todas las acciones del pipeline
CREATE TABLE IF NOT EXISTS public.operations (
    operation_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    operation_type_id    UUID REFERENCES public.operation_types(operation_type_id),
    collaborator_id      UUID REFERENCES public.collaborators(collaborator_id),
    logged_at            TIMESTAMPTZ DEFAULT NOW(),
    slurm_job_id         TEXT,
    transkribus_job_id   TEXT,
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

-- Notas sobre documentos (semántica: "esta nota extiende la descripción de este documento")
CREATE TABLE IF NOT EXISTS public.notes_documents (
    note_id              UUID NOT NULL REFERENCES public.notes(note_id),
    document_id          UUID NOT NULL REFERENCES public.documents(document_id),
    PRIMARY KEY (note_id, document_id)
);

-- Notas sobre colecciones
CREATE TABLE IF NOT EXISTS public.notes_collections (
    note_id              UUID NOT NULL REFERENCES public.notes(note_id),
    collection_id        UUID NOT NULL REFERENCES public.collections(collection_id),
    PRIMARY KEY (note_id, collection_id)
);

-- Notas sobre imágenes
CREATE TABLE IF NOT EXISTS public.notes_images (
    note_id              UUID NOT NULL REFERENCES public.notes(note_id),
    image_id             UUID NOT NULL REFERENCES public.images(image_id),
    PRIMARY KEY (note_id, image_id)
);

-- Notas vinculadas a su operación de creación/modificación
CREATE TABLE IF NOT EXISTS public.notes_operations (
    note_id              UUID NOT NULL REFERENCES public.notes(note_id),
    operation_id         UUID NOT NULL REFERENCES public.operations(operation_id),
    PRIMARY KEY (note_id, operation_id)
);

CREATE TABLE IF NOT EXISTS public.documents_document_types (
    document_id          UUID REFERENCES public.documents(document_id),
    document_type_id     UUID REFERENCES public.document_types(document_type_id),
    PRIMARY KEY (document_id, document_type_id)
);

CREATE TABLE IF NOT EXISTS public.documents_study_cases (
    document_id          UUID REFERENCES public.documents(document_id),
    study_case_id        UUID REFERENCES public.study_cases(study_case_id),
    PRIMARY KEY (document_id, study_case_id)
);

CREATE TABLE IF NOT EXISTS public.collections_operations (
    collection_id        UUID REFERENCES public.collections(collection_id),
    operation_id         UUID REFERENCES public.operations(operation_id),
    PRIMARY KEY (collection_id, operation_id)
);

CREATE TABLE IF NOT EXISTS public.documents_operations (
    document_id          UUID REFERENCES public.documents(document_id),
    operation_id         UUID REFERENCES public.operations(operation_id),
    PRIMARY KEY (document_id, operation_id)
);

CREATE TABLE IF NOT EXISTS public.images_operations (
    image_id             UUID REFERENCES public.images(image_id),
    operation_id         UUID REFERENCES public.operations(operation_id),
    PRIMARY KEY (image_id, operation_id)
);

CREATE TABLE IF NOT EXISTS public.htr_operations (
    htr_id               UUID REFERENCES public.htr(htr_id),
    operation_id         UUID REFERENCES public.operations(operation_id),
    PRIMARY KEY (htr_id, operation_id)
);

CREATE TABLE IF NOT EXISTS public.models_operations (
    model_id             UUID REFERENCES public.models(model_id),
    operation_id         UUID REFERENCES public.operations(operation_id),
    PRIMARY KEY (model_id, operation_id)
);

CREATE TABLE IF NOT EXISTS public.collaborators_roles (
    collaborator_id      UUID REFERENCES public.collaborators(collaborator_id),
    role_id              UUID REFERENCES public.roles(role_id),
    PRIMARY KEY (collaborator_id, role_id)
);

CREATE TABLE IF NOT EXISTS public.htr_entities (
    htr_id               UUID REFERENCES public.htr(htr_id),
    entity_id            UUID REFERENCES public.entities(entity_id),
    PRIMARY KEY (htr_id, entity_id)
);

CREATE TABLE IF NOT EXISTS public.entities_entity_types (
    entity_id            UUID REFERENCES public.entities(entity_id),
    entity_type_id       UUID REFERENCES public.entity_types(entity_type_id),
    PRIMARY KEY (entity_id, entity_type_id)
);

CREATE TABLE IF NOT EXISTS public.htr_abbreviations (
    htr_id               UUID REFERENCES public.htr(htr_id),
    abbreviation_id      UUID REFERENCES public.abbreviations(abbreviation_id),
    PRIMARY KEY (htr_id, abbreviation_id)
);

CREATE TABLE IF NOT EXISTS public.abbreviations_expansions (
    abbreviation_id      UUID REFERENCES public.abbreviations(abbreviation_id),
    expansion_id         UUID REFERENCES public.expansions(expansion_id),
    PRIMARY KEY (abbreviation_id, expansion_id)
);

CREATE TABLE IF NOT EXISTS public.htr_errors (
    htr_id               UUID REFERENCES public.htr(htr_id),
    error_id             UUID REFERENCES public.errors(error_id),
    PRIMARY KEY (htr_id, error_id)
);

CREATE TABLE IF NOT EXISTS public.htr_patterns (
    htr_id               UUID REFERENCES public.htr(htr_id),
    pattern_id           UUID REFERENCES public.patterns(pattern_id),
    PRIMARY KEY (htr_id, pattern_id)
);

CREATE TABLE IF NOT EXISTS public.images_image_statuses (
    image_id             UUID REFERENCES public.images(image_id),
    image_status_id      UUID REFERENCES public.image_statuses(image_status_id),
    PRIMARY KEY (image_id, image_status_id)
);

-- ---------------------------------------------------------------------------
-- SCHEMA RAG — base de conocimiento vectorial (UUID ya existente, no se toca)
-- ---------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS rag;

CREATE TABLE IF NOT EXISTS rag.knowledge_base (
    knowledge_base_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    knowledge_base_type  TEXT NOT NULL
        CHECK (knowledge_base_type IN
            ('abbreviation', 'entity', 'error_pattern', 'document_knowledge')),
    abbreviation_id      UUID REFERENCES public.abbreviations(abbreviation_id),
    expansion_id         UUID REFERENCES public.expansions(expansion_id),
    entity_id            UUID REFERENCES public.entities(entity_id),
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

-- ---------------------------------------------------------------------------
-- DATOS SEMILLA — catálogos
-- ---------------------------------------------------------------------------

-- collection_types
INSERT INTO public.collection_types (collection_type) VALUES
    ('AGN'),
    ('AMP'),
    ('BP'),
    ('AGI'),
    ('corpus_local'),
    ('ground_truth_collection')
ON CONFLICT (collection_type) DO NOTHING;

-- collection_statuses
INSERT INTO public.collection_statuses (collection_status) VALUES
    ('new'),
    ('documents_in_queue'),
    ('ready')
ON CONFLICT (collection_status) DO NOTHING;

-- archival_institutions
INSERT INTO public.archival_institutions (archival_institution_name, archival_institution_short) VALUES
    ('Archivo General de la Nación',      'AGN'),
    ('Archivo Municipal de Puebla',       'AMP'),
    ('Biblioteca Palafoxiana',            'BP'),
    ('Archivo General de Indias',         'AGI')
ON CONFLICT (archival_institution_name) DO NOTHING;

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
    ('new'),
    ('htr_available'),
    ('hist_clean'),
    ('clean_modern'),
    ('annotated'),
    ('nlp_ready')
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
    ('layout_sent'),
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
    ('orthographic',  'Variaciones ortográficas históricas predecibles'),
    ('abbreviation',  'Abreviaturas con expansión conocida'),
    ('phonetic',      'Errores fonéticos del OCR/HTR'),
    ('morphological', 'Errores morfológicos en flexión'),
    ('proper_noun',   'Errores en nombres propios')
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
    ('admin'),
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

-- operation_types
INSERT INTO public.operation_types (operation_type, description, entity_scope) VALUES
    -- Ingesta
    ('collection_registered',         'Metadatos de colección registrados en BD',              'collection'),
    ('document_registered',           'Documento registrado con campos archivísticos',          'document'),
    ('images_downloaded',             'Imágenes descargadas desde fuente externa',              'collection'),
    ('image_registered',              'Imagen (página) registrada en BD',                       'image'),
    -- Notas
    ('note_created',                  'Nota creada y vinculada a su entidad',                   'note'),
    ('note_modified',                 'Nota modificada',                                        'note'),
    -- Preprocesamiento
    ('image_preprocessed',            'Ecualización de histograma aplicada',                    'image'),
    -- Transkribus
    ('layout_retrieved',              'Layout XML obtenido de Transkribus',                     'image'),
    ('typography_classified',         'Tipo de caligrafía asignado',                            'image'),
    ('htr_available',                 'HTR generado y almacenado localmente',                   'htr'),
    -- Limpieza
    ('htr_cleaning_started',          'Proceso de limpieza histórica iniciado',                 'htr'),
    ('htr_cleaning_completed',        'Limpieza histórica completada',                          'htr'),
    ('historical_clean_available',    'Versión histórica limpia disponible',                    'htr'),
    ('clean_modern_available',        'Versión modernizada disponible',                         'htr'),
    -- Revisión y análisis
    ('descriptive_analysis_computed', 'Análisis descriptivo calculado y registrado',            'document'),
    ('document_to_review',            'Documento encolado para revisión humana',                'document'),
    ('document_reviewed',             'Revisión humana completada',                             'document'),
    -- Ground truth
    ('ground_truth_registered',       'Archivo ground_truth vinculado a HTR',                   'htr'),
    -- Modelos
    ('model_registered',              'Modelo de ML registrado en BD',                          'model'),
    ('model_evaluated',               'Modelo evaluado contra conjunto de prueba',              'model'),
    ('model_deployed',                'Modelo marcado como activo para el pipeline',            'model'),
    -- Anotación y base de conocimiento
    ('entity_verified',               'Entidad verificada por paleógrafo',                      'system'),
    ('correction_applied',            'Corrección de error aplicada',                           'system'),
    ('expansion_added',               'Expansión de abreviatura añadida',                       'system'),
    ('abbreviation_resolved',         'Abreviatura resuelta en contexto',                       'system'),
    ('annotation_synced',             'Archivo JSON de anotación importado desde GitHub',       'system'),
    ('knowledge_base_rebuilt',        'Base de conocimiento RAG reconstruida',                  'system'),
    -- Sistema
    ('annotation_export_generated',   'JSON de estado exportado para aplicación de anotación', 'system'),
    ('db_backup_created',             'Backup de PostgreSQL creado',                            'system'),
    ('schema_migrated',               'Schema SQL aplicado o actualizado',                      'system')
ON CONFLICT (operation_type) DO NOTHING;

-- ---------------------------------------------------------------------------
-- SEED — colaborador administrador
-- ---------------------------------------------------------------------------

INSERT INTO public.collaborators (collaborator_name)
VALUES ('amoxcailab')
ON CONFLICT (collaborator_name) DO NOTHING;

INSERT INTO public.collaborators_roles (collaborator_id, role_id)
SELECT c.collaborator_id, r.role_id
FROM public.collaborators c
CROSS JOIN public.roles r
WHERE c.collaborator_name = 'amoxcailab'
  AND r.role_name = 'admin'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- VISTAS — por collection_type (ingestión)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW public.v_collections AS
SELECT
    c.collection_id,
    c.collection_name,
    c.collection_path,
    c.collection_url,
    ct.collection_type,
    cs.collection_status,
    ai.archival_institution_name,
    ai.archival_institution_short
FROM public.collections c
LEFT JOIN public.collection_types        ct USING (collection_type_id)
LEFT JOIN public.collection_statuses     cs USING (collection_status_id)
LEFT JOIN public.archival_institutions   ai USING (archival_institution_id);

CREATE OR REPLACE VIEW public.v_documents_agn AS
SELECT
    d.document_id,
    d.collection_id,
    d.document_name,
    d.document_path,
    d.document_archive,
    d.document_Fondo,
    d.document_Volumen,
    d.document_Caja,
    d.document_Legajo,
    d.document_Expediente,
    d.document_Fecha_creacion,
    d.document_Año_creacion,
    d.document_Lugar_creacion,
    d.document_Soporte,
    d.document_Descripcion,
    d.document_Rango_fojas,
    d.document_Num_pags,
    d.document_Num_pags_escritas,
    ds.document_status
FROM public.documents d
JOIN public.document_statuses ds USING (document_status_id)
JOIN public.collections c USING (collection_id)
JOIN public.collection_types ct USING (collection_type_id)
WHERE ct.collection_type = 'AGN';

CREATE OR REPLACE VIEW public.v_documents_amp AS
SELECT
    d.document_id,
    d.collection_id,
    d.document_name,
    d.document_path,
    d.document_archive,
    d.document_Fondo,
    d.document_Volumen,
    d.document_Tomo,
    d.document_Legajo,
    d.document_Documento,
    d.document_Fecha_creacion,
    d.document_Año_creacion,
    d.document_Lugar_creacion,
    d.document_Descripcion,
    d.document_Rango_fojas,
    d.document_Num_pags,
    d.document_Num_pags_escritas,
    ds.document_status
FROM public.documents d
JOIN public.document_statuses ds USING (document_status_id)
JOIN public.collections c USING (collection_id)
JOIN public.collection_types ct USING (collection_type_id)
WHERE ct.collection_type = 'AMP';

CREATE OR REPLACE VIEW public.v_documents_bp AS
SELECT
    d.document_id,
    d.collection_id,
    d.document_name,
    d.document_path,
    d.document_archive,
    d.document_Fondo,
    d.document_Volumen,
    d.document_Expediente,
    d.document_Fecha_creacion,
    d.document_Año_creacion,
    d.document_Lugar_creacion,
    d.document_Rango_fojas,
    d.document_Num_pags,
    d.document_Num_pags_escritas,
    ds.document_status
FROM public.documents d
JOIN public.document_statuses ds USING (document_status_id)
JOIN public.collections c USING (collection_id)
JOIN public.collection_types ct USING (collection_type_id)
WHERE ct.collection_type = 'BP';

CREATE OR REPLACE VIEW public.v_documents_agi AS
SELECT
    d.document_id,
    d.collection_id,
    d.document_name,
    d.document_path,
    d.document_archive,
    d.document_Titulo,
    d.document_Signatura,
    d.document_Productores,
    d.document_Indices_de_Descripcion,
    d.document_Fecha_creacion,
    d.document_Año_creacion,
    d.document_Lugar_creacion,
    d.document_Soporte,
    d.document_Descripcion,
    d.document_Num_pags,
    ds.document_status
FROM public.documents d
JOIN public.document_statuses ds USING (document_status_id)
JOIN public.collections c USING (collection_id)
JOIN public.collection_types ct USING (collection_type_id)
WHERE ct.collection_type = 'AGI';

-- ---------------------------------------------------------------------------
-- VISTAS — observabilidad del pipeline
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW public.v_pipeline_status AS
SELECT
    d.document_id,
    d.document_name,
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

CREATE OR REPLACE VIEW public.v_quality_metrics AS
SELECT
    c.collection_name,
    at2.analysis_type,
    ROUND(AVG(da.cer)::NUMERIC, 4)                 AS avg_cer,
    ROUND(AVG(da.wer)::NUMERIC, 4)                 AS avg_wer,
    ROUND(AVG(da.bleu)::NUMERIC, 2)                AS avg_bleu,
    ROUND(AVG(da.entity_preservation)::NUMERIC, 4) AS avg_entity_preservation,
    COUNT(da.descriptive_analysis_id)               AS n_analyses
FROM public.descriptive_analysis da
JOIN public.documents d ON da.document_id = d.document_id
JOIN public.collections c ON d.collection_id = c.collection_id
JOIN public.analysis_types at2 ON da.analysis_type_id = at2.analysis_type_id
GROUP BY c.collection_name, at2.analysis_type;

COMMIT;
