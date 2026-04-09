-- ============================================================
-- SCHEMA INTEGRADO — HTR PIPELINE
-- BD local · Servidor Schmidt Sciences
-- PostgreSQL 15+ con extensión pgvector
-- ============================================================
-- Estructura:
--   public.*        tablas originales del proyecto
--   pipeline.*      observabilidad del pipeline
--   rag.*           knowledge bases (KB-1, KB-2, KB-3)
-- ============================================================

-- ------------------------------------------------------------
-- EXTENSIONES
-- ------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";   -- UUIDs v4
CREATE EXTENSION IF NOT EXISTS "vector";      -- pgvector para embeddings RAG

-- ------------------------------------------------------------
-- SCHEMAS
-- ------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS pipeline;
CREATE SCHEMA IF NOT EXISTS rag;


-- ============================================================
-- SCHEMA PUBLIC — TABLAS ORIGINALES
-- Se respetan typos existentes para no romper código en prod.
-- ============================================================

SET search_path TO public;

-- ------------------------------------------------------------
-- Tablas maestras
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public."Calligraphy_Types" (
    calligraphy_id   INTEGER PRIMARY KEY,
    calligraphy_type TEXT
);

CREATE TABLE IF NOT EXISTS public."Case_Studies" (
    case_study_id INTEGER PRIMARY KEY,
    case_study    TEXT
);

CREATE TABLE IF NOT EXISTS public."Collaborators" (
    "collab_ID"      INTEGER PRIMARY KEY,
    col_name         TEXT,
    col_affiliation  TEXT
);

CREATE TABLE IF NOT EXISTS public."Instit_Collec_Proj_Key" (
    inst_coll_proj_id          INTEGER PRIMARY KEY,
    inst_collection_project_name TEXT
);

CREATE TABLE IF NOT EXISTS public."Languages" (
    language_id   INTEGER PRIMARY KEY,
    language_name TEXT
);

CREATE TABLE IF NOT EXISTS public."Types_Of_Documents" (
    document_type_id INTEGER PRIMARY KEY,
    document_type    TEXT
);

CREATE TABLE IF NOT EXISTS public."Transcription_Availables" (
    transcription_id INTEGER PRIMARY KEY,
    description      TEXT
);

CREATE TABLE IF NOT EXISTS public."Places" (
    place_id  INTEGER PRIMARY KEY,
    placename TEXT,
    country   TEXT
);

-- ------------------------------------------------------------
-- Tabla central de documentos
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public."Documents" (
    doc_id                  INTEGER PRIMARY KEY,
    inst_coll_proj_id       INTEGER REFERENCES public."Instit_Collec_Proj_Key"(inst_coll_proj_id),
    digitalizo_collab_id    INTEGER REFERENCES public."Collaborators"("collab_ID"),
    document_internal_id    TEXT,
    title                   TEXT,
    description             TEXT,
    transcribio_collab_id   INTEGER REFERENCES public."Collaborators"("collab_ID")
);

-- ------------------------------------------------------------
-- Registros de archivo por institución
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public."AGI_Doc_Record" (
    doc_record_id       INTEGER PRIMARY KEY,
    "AGI_ref_number"    TEXT,
    "AGI_reference_code" TEXT
);

CREATE TABLE IF NOT EXISTS public."AGN_Doc_Record" (
    doc_record_id       INTEGER PRIMARY KEY,
    "AGN_ref_number"    TEXT,
    "AGN_reference_code" TEXT
);

CREATE TABLE IF NOT EXISTS public."AMP_Doc_Record" (
    doc_record_id       INTEGER PRIMARY KEY,
    "AMP_ref_number"    TEXT,
    "AMP_reference_code" TEXT
);

CREATE TABLE IF NOT EXISTS public."BP_Doc_Record" (
    doc_record_id       INTEGER PRIMARY KEY,
    "BP_ref_number"     TEXT,
    "BP_reference_code" TEXT
);

CREATE TABLE IF NOT EXISTS public."LoC_Doc_Record" (
    doc_id     INTEGER REFERENCES public."Documents"(doc_id),
    collection TEXT,
    container  TEXT,
    medium     TEXT
);

CREATE TABLE IF NOT EXISTS public."Other_Collec_Doc_Record" (
    doc_id     INTEGER REFERENCES public."Documents"(doc_id),
    collection TEXT,
    identifier TEXT
);

-- ------------------------------------------------------------
-- Tablas de relación de documentos
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public."Document_Calligraphy" (
    doc_id         INTEGER REFERENCES public."Documents"(doc_id),
    calligraphy_id INTEGER REFERENCES public."Calligraphy_Types"(calligraphy_id),
    notes          TEXT
);

CREATE TABLE IF NOT EXISTS public."Document_Case_Studies" (
    doc_id        INTEGER REFERENCES public."Documents"(doc_id),
    case_study_id INTEGER REFERENCES public."Case_Studies"(case_study_id)
);

CREATE TABLE IF NOT EXISTS public."Document_Dates" (
    doc_id            INTEGER REFERENCES public."Documents"(doc_id),
    date_created      DATE,
    year              INTEGER,
    approximated_date INTEGER
);

CREATE TABLE IF NOT EXISTS public."Document_Languages" (
    doc_id      INTEGER REFERENCES public."Documents"(doc_id),
    language_id INTEGER REFERENCES public."Languages"(language_id),
    pages       TEXT
);

CREATE TABLE IF NOT EXISTS public."Document_Places" (
    document_id INTEGER REFERENCES public."Documents"(doc_id),
    place_id     INTEGER REFERENCES public."Places"(place_id)  -- typo "place_id" preservado
);

-- Tabla con typo preservado del original
CREATE TABLE IF NOT EXISTS public."Document_Places" (
    document_id INTEGER REFERENCES public."Documents"(doc_id)
);

CREATE TABLE IF NOT EXISTS public."Document_Types" (
    doc_id  INTEGER REFERENCES public."Documents"(doc_id),
    type_id INTEGER REFERENCES public."Types_Of_Documents"(document_type_id)
);

CREATE TABLE IF NOT EXISTS public."Document_Reviewers" (
    transcription_id INTEGER,
    collab_id        INTEGER REFERENCES public."Collaborators"("collab_ID")
);

CREATE TABLE IF NOT EXISTS public."Documents_Collaborators" (
    doc_id    INTEGER REFERENCES public."Documents"(doc_id),
    collab_id INTEGER REFERENCES public."Collaborators"("collab_ID"),
    role      TEXT
);

-- ------------------------------------------------------------
-- Modelos ML y uso
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public."ML_Models_Key" (
    "Mod_ID"              INTEGER PRIMARY KEY,
    "Model_Version"       TEXT,
    "Model"               TEXT,
    "NN_Type"             TEXT,
    bash_number           INTEGER,
    iterations_number     INTEGER,
    epochs                INTEGER,
    learning_rate         NUMERIC,
    "precision"           NUMERIC,
    recall                NUMERIC,
    "F1_Score"            NUMERIC,
    model_lead_collab_id  INTEGER REFERENCES public."Collaborators"("collab_ID")
);

CREATE TABLE IF NOT EXISTS public."Model_Use" (
    model_use_id INTEGER PRIMARY KEY,
    doc_id       INTEGER REFERENCES public."Documents"(doc_id),
    mod_id       INTEGER REFERENCES public."ML_Models_Key"("Mod_ID")
);

-- ------------------------------------------------------------
-- Transcripciones
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public."Transcriptions" (
    "transcriptionID"      INTEGER PRIMARY KEY,
    document_id            INTEGER REFERENCES public."Documents"(doc_id),
    transcribed_lines      INTEGER,
    transcribed_words      INTEGER,
    transcription_available TEXT
);

CREATE TABLE IF NOT EXISTS public."Transcribers" (
    transcription_id INTEGER,
    collab_id        INTEGER REFERENCES public."Collaborators"("collab_ID")
);

CREATE TABLE IF NOT EXISTS public."Reviewers" (
    transcription_id INTEGER,
    collab_id        INTEGER REFERENCES public."Collaborators"("collab_ID")
);

-- ------------------------------------------------------------
-- NLP y URLs
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public."NLP_Annotation" (
    annotation_id   INTEGER PRIMARY KEY,
    doc_id          INTEGER REFERENCES public."Documents"(doc_id),
    annotation_data TEXT
);

CREATE TABLE IF NOT EXISTS public."URLs" (
    doc_id              INTEGER REFERENCES public."Documents"(doc_id),
    image_url           TEXT,
    "IIIF_manifesto"    TEXT,
    transcriptions_url  TEXT,
    nlp_annotation_url  TEXT
);

-- ------------------------------------------------------------
-- Transkribus workflow
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public."Transkribus_Status" (
    status_id   INTEGER PRIMARY KEY,
    status_name TEXT
);

CREATE TABLE IF NOT EXISTS public."Transkribus_Workflow" (
    workflow_id   INTEGER PRIMARY KEY,
    workflow_name TEXT
);

CREATE TABLE IF NOT EXISTS public."HRT_Status" (
    status_id   INTEGER PRIMARY KEY,
    status_name TEXT
);

CREATE TABLE IF NOT EXISTS public."HRT_Status_Transkribus_Workflow" (
    status_id   INTEGER,
    workflow_id INTEGER
);


-- ============================================================
-- SCHEMA PIPELINE — OBSERVABILIDAD
-- ============================================================
-- Nomenclatura de status por documento:
--   clean              sin entidades no verificadas · métricas OK
--   provisional        n_partial > 0 pero bajo umbral · avanza
--   blocked_entities   n_unmatched > umbral_bloqueo · skip PASO 7
--   rejected           doc_id no válido en PC-1
--   requires_manual_review  superó reentry_max_count
-- ============================================================

SET search_path TO pipeline, public;

-- ------------------------------------------------------------
-- pipeline_config
-- Parámetros configurables entre ejecuciones. Clave única tipo k/v.
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS pipeline.pipeline_config (
    key          TEXT PRIMARY KEY,
    value        TEXT        NOT NULL,
    description  TEXT,
    updated_at   TIMESTAMPTZ DEFAULT NOW(),
    updated_by   TEXT
);

-- Valores por defecto
INSERT INTO pipeline.pipeline_config (key, value, description) VALUES
  ('umbral_bloqueo',         '5',    'n_unmatched máximo antes de bloquear un documento en PC-3a'),
  ('umbral_reentrada',       '50',   'entidades nuevas verificadas en KB-3 que disparan re-entrada'),
  ('reentry_max_count',      '5',    'máximo de re-entradas por documento antes de requires_manual_review'),
  ('umbral_minimo_kb2',      '100',  'pares mínimos en KB-2 para activar RAG-2 en PASO 7'),
  ('cer_objetivo',           '3.0',  'CER máximo aceptable post-HistClean (%)'),
  ('bleu_objetivo',          '70.0', 'BLEU mínimo aceptable post-Hist2Mod'),
  ('chrf_objetivo',          '70.0', 'ChrF++ mínimo aceptable post-Hist2Mod'),
  ('entity_preservation_min','98.0', 'entity preservation mínimo (%) en PC-4'),
  ('tasa_expansion_min',     '95.0', 'tasa de expansión de abreviaturas mínima en PC-2 (%)'),
  ('kb3_search_threshold_high', '0.85', 'umbral de similitud coseno para búsqueda normal en KB-3'),
  ('kb3_search_threshold_low',  '0.60', 'umbral de similitud coseno para búsqueda expandida en KB-3'),
  ('kb1_k_results',          '5',    'número de ejemplos K que recupera RAG-1 por abreviatura'),
  ('kb3_k_results',          '3',    'número de ejemplos K que recupera RAG-3 por entidad')
ON CONFLICT (key) DO NOTHING;


-- ------------------------------------------------------------
-- pipeline_runs
-- Una fila por ejecución de lote (batch). Incluye re-entradas.
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS pipeline.pipeline_runs (
    id                              UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    parent_run_id                   UUID        REFERENCES pipeline.pipeline_runs(id),
    is_reentry                      BOOLEAN     DEFAULT FALSE,
    reentry_triggered_by_kb3_count  INTEGER,    -- cuántas entidades nuevas dispararon esta re-entrada
    batch_name                      TEXT,
    started_at                      TIMESTAMPTZ DEFAULT NOW(),
    completed_at                    TIMESTAMPTZ,
    status                          TEXT        NOT NULL DEFAULT 'running'
                                    CHECK (status IN ('running','completed','failed','partial')),
    -- Conteos resumen del lote
    total_docs                      INTEGER     DEFAULT 0,
    n_clean                         INTEGER     DEFAULT 0,
    n_provisional                   INTEGER     DEFAULT 0,
    n_blocked                       INTEGER     DEFAULT 0,
    n_rejected                      INTEGER     DEFAULT 0,
    -- Metadatos de ejecución
    slurm_job_id                    TEXT,
    launched_by                     TEXT,
    notes                           TEXT
);

CREATE INDEX IF NOT EXISTS idx_pipeline_runs_status
    ON pipeline.pipeline_runs(status);
CREATE INDEX IF NOT EXISTS idx_pipeline_runs_parent
    ON pipeline.pipeline_runs(parent_run_id);


-- ------------------------------------------------------------
-- pipeline_document_trace
-- Una fila por (run_id, doc_id). Registra el recorrido completo
-- de cada documento a través de todos los pasos y puntos de
-- control. clean_text_url se guarda siempre, incluso para
-- documentos bloqueados, para permitir re-entrada desde PASO 6.
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS pipeline.pipeline_document_trace (
    id              UUID    PRIMARY KEY DEFAULT uuid_generate_v4(),
    run_id          UUID    NOT NULL REFERENCES pipeline.pipeline_runs(id),
    doc_id          INTEGER NOT NULL REFERENCES public."Documents"(doc_id),
    parent_run_id   UUID    REFERENCES pipeline.pipeline_runs(id),  -- run original si es re-entrada
    reentry_count   INTEGER DEFAULT 0,
    last_reentry_run_id UUID REFERENCES pipeline.pipeline_runs(id),

    -- ── Estado final del documento ──────────────────────────
    status          TEXT    NOT NULL DEFAULT 'in_progress'
                    CHECK (status IN (
                        'in_progress',
                        'clean',
                        'provisional',
                        'blocked_entities',
                        'rejected',
                        'requires_manual_review'
                    )),

    -- ── Clasificación ───────────────────────────────────────
    handwriting_type        TEXT,   -- Itálica cursiva | Procesal | Redonda | Encadenada
    classifier_confidence   NUMERIC(5,4),
    transkribus_model_used  TEXT,   -- m3t1 | m3t7 | m1t3 | m2t4

    -- ── Métricas de calidad (CER en %) ──────────────────────
    cer_baseline            NUMERIC(6,3),   -- vs GT si disponible
    cer_post_heuristics     NUMERIC(6,3),   -- delta = cer_post_heuristics - cer_baseline
    cer_post_histclean      NUMERIC(6,3),
    abbreviation_expansion_rate NUMERIC(5,2),  -- % abreviaturas expandidas

    -- ── Métricas post-Hist2Mod ──────────────────────────────
    bleu_score              NUMERIC(6,3),
    chrf_score              NUMERIC(6,3),
    entity_preservation     NUMERIC(5,2),   -- %
    filological_compliance  NUMERIC(5,2),   -- % sobre ~25 reglas

    -- ── Validación de entidades (RAG-3) ─────────────────────
    n_entities_total        INTEGER DEFAULT 0,
    n_verified              INTEGER DEFAULT 0,   -- match + verified=true en KB-3
    n_partial               INTEGER DEFAULT 0,   -- match parcial (búsqueda expandida)
    n_unmatched             INTEGER DEFAULT 0,   -- sin ningún match

    -- ── URLs de outputs en filesystem ───────────────────────
    image_processed_url     TEXT,
    htr_raw_url             TEXT,
    diff_heuristics_url     TEXT,
    clean_text_url          TEXT,   -- siempre guardado · necesario para re-entrada
    modern_text_url         TEXT,

    -- ── Timestamps por punto de control ─────────────────────
    paso0_at    TIMESTAMPTZ,  -- ingesta y registro
    pc0_at      TIMESTAMPTZ,  -- clasificador
    pc1_at      TIMESTAMPTZ,  -- validación ingesta
    pc2_at      TIMESTAMPTZ,  -- post-heurísticas
    pc3_at      TIMESTAMPTZ,  -- decisión de ruteo
    pc4_at      TIMESTAMPTZ,  -- post-Hist2Mod
    pc5_at      TIMESTAMPTZ,  -- validación final del lote

    -- ── Flags y observaciones ───────────────────────────────
    flag_low_classifier_confidence  BOOLEAN DEFAULT FALSE,
    flag_negative_cer_delta         BOOLEAN DEFAULT FALSE,  -- carril amarillo
    flag_entity_preservation_fail   BOOLEAN DEFAULT FALSE,  -- carril rojo
    flags_json                      JSONB,  -- flags adicionales extensibles

    created_at  TIMESTAMPTZ DEFAULT NOW(),
    updated_at  TIMESTAMPTZ DEFAULT NOW(),

    UNIQUE (run_id, doc_id)
);

CREATE INDEX IF NOT EXISTS idx_trace_run_id
    ON pipeline.pipeline_document_trace(run_id);
CREATE INDEX IF NOT EXISTS idx_trace_doc_id
    ON pipeline.pipeline_document_trace(doc_id);
CREATE INDEX IF NOT EXISTS idx_trace_status
    ON pipeline.pipeline_document_trace(status);
CREATE INDEX IF NOT EXISTS idx_trace_reentry
    ON pipeline.pipeline_document_trace(reentry_count)
    WHERE reentry_count > 0;


-- ------------------------------------------------------------
-- pipeline_run_metrics
-- Registro granular de métricas por paso y documento.
-- Permite trazar evolución histórica entre ejecuciones.
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS pipeline.pipeline_run_metrics (
    id           UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    run_id       UUID        NOT NULL REFERENCES pipeline.pipeline_runs(id),
    doc_id       INTEGER     REFERENCES public."Documents"(doc_id),
    step_name    TEXT        NOT NULL,  -- paso0 | paso1 | pc1 | paso5 | pc2 | paso6 | pc3 | paso7 | pc4 | pc5
    metric_name  TEXT        NOT NULL,
    metric_value NUMERIC,
    metric_text  TEXT,                  -- para métricas no numéricas
    recorded_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_metrics_run_doc
    ON pipeline.pipeline_run_metrics(run_id, doc_id);
CREATE INDEX IF NOT EXISTS idx_metrics_step
    ON pipeline.pipeline_run_metrics(step_name);


-- ------------------------------------------------------------
-- pipeline_review_queue
-- Cola de documentos que requieren revisión humana.
-- Bloqueados: prioridad alta. Provisionales: prioridad baja.
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS pipeline.pipeline_review_queue (
    id                   UUID    PRIMARY KEY DEFAULT uuid_generate_v4(),
    run_id               UUID    NOT NULL REFERENCES pipeline.pipeline_runs(id),
    doc_id               INTEGER NOT NULL REFERENCES public."Documents"(doc_id),
    trace_id             UUID    REFERENCES pipeline.pipeline_document_trace(id),
    priority             TEXT    NOT NULL DEFAULT 'low'
                         CHECK (priority IN ('high', 'low')),
    status               TEXT    NOT NULL DEFAULT 'pending'
                         CHECK (status IN ('pending', 'in_review', 'completed', 'deferred')),
    reason               TEXT    NOT NULL,  -- 'blocked_entities' | 'provisional' | 'entity_preservation_fail'
    n_entities_pending   INTEGER DEFAULT 0, -- n_unmatched + n_partial al momento de encolar
    assigned_to          INTEGER REFERENCES public."Collaborators"("collab_ID"),
    created_at           TIMESTAMPTZ DEFAULT NOW(),
    updated_at           TIMESTAMPTZ DEFAULT NOW(),

    UNIQUE (run_id, doc_id)
);

CREATE INDEX IF NOT EXISTS idx_queue_priority_status
    ON pipeline.pipeline_review_queue(priority, status);
CREATE INDEX IF NOT EXISTS idx_queue_doc_id
    ON pipeline.pipeline_review_queue(doc_id);


-- ------------------------------------------------------------
-- pipeline_human_review
-- Cada acción que un colaborador toma sobre una entidad o
-- una corrección de modernización. Alimenta KB-2 y KB-3.
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS pipeline.pipeline_human_review (
    id                  UUID    PRIMARY KEY DEFAULT uuid_generate_v4(),
    review_queue_id     UUID    REFERENCES pipeline.pipeline_review_queue(id),
    doc_id              INTEGER NOT NULL REFERENCES public."Documents"(doc_id),
    run_id              UUID    NOT NULL REFERENCES pipeline.pipeline_runs(id),
    collab_id           INTEGER REFERENCES public."Collaborators"("collab_ID"),

    -- ── Tipo de revisión ─────────────────────────────────────
    review_type         TEXT    NOT NULL
                        CHECK (review_type IN (
                            'entity_verification',     -- revisión de entidad para KB-3
                            'modernization_correction', -- par limpio→moderno para KB-2
                            'general_quality'          -- score de calidad general
                        )),

    -- ── Para entity_verification ────────────────────────────
    entity_raw_text     TEXT,           -- texto tal como aparece en el documento
    entity_type         TEXT,           -- person | place | title | date | org
    entity_canonical    TEXT,           -- forma canónica validada o corregida
    entity_action       TEXT
                        CHECK (entity_action IN ('confirmed', 'corrected', 'rejected')),

    -- ── Para modernization_correction ───────────────────────
    original_text       TEXT,           -- token en español early-modern
    modernized_text     TEXT,           -- forma modernizada validada
    is_training_candidate BOOLEAN DEFAULT FALSE,

    -- ── Score general de calidad (1–5) ───────────────────────
    quality_score       INTEGER CHECK (quality_score BETWEEN 1 AND 5),

    -- ── Referencia a la entrada KB creada ───────────────────
    kb_entry_id         UUID,           -- FK a rag.knowledge_base.id si se creó entrada

    notes               TEXT,
    reviewed_at         TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_review_doc_id
    ON pipeline.pipeline_human_review(doc_id);
CREATE INDEX IF NOT EXISTS idx_review_type
    ON pipeline.pipeline_human_review(review_type);
CREATE INDEX IF NOT EXISTS idx_review_is_training
    ON pipeline.pipeline_human_review(is_training_candidate)
    WHERE is_training_candidate = TRUE;


-- ============================================================
-- SCHEMA RAG — KNOWLEDGE BASES
-- KB-1: abreviaturas      kb_type = 'abbreviation'
-- KB-2: modernización     kb_type = 'modernization'
-- KB-3: entidades         kb_type = 'entity'
-- ============================================================

SET search_path TO rag, public;

-- ------------------------------------------------------------
-- rag.knowledge_base
-- Tabla unificada para las tres KBs. El campo embedding
-- usa el tipo vector de pgvector (1536 dims para OpenAI
-- text-embedding-3-small o equivalente; ajustar según modelo).
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS rag.knowledge_base (
    id              UUID    PRIMARY KEY DEFAULT uuid_generate_v4(),
    kb_type         TEXT    NOT NULL
                    CHECK (kb_type IN ('abbreviation', 'entity', 'modernization')),

    -- ── Texto fuente y forma canónica ───────────────────────
    source_text     TEXT    NOT NULL,   -- abreviatura / variante ortográfica / token raro
    canonical_form  TEXT    NOT NULL,   -- expansión / forma canónica / forma modernizada
    context_fragment TEXT,              -- fragmento de oración para RAG contextual

    -- ── Embedding vectorial ──────────────────────────────────
    embedding       vector(1536),       -- ajustar dimensión según modelo de embeddings

    -- ── Estado de verificación ──────────────────────────────
    verified        BOOLEAN DEFAULT FALSE,  -- TRUE = validado por historiador
    -- Solo KB-3: entidades del GT entran con verified=TRUE desde JOB 0

    -- ── Filtros de recuperación ──────────────────────────────
    -- KB-1: filtros para RAG-1
    handwriting_type TEXT,              -- Itálica cursiva | Procesal | Redonda | Encadenada | NULL=todos
    century         INTEGER,            -- 16 | 17 | 18 | NULL=todos

    -- KB-3: filtros para búsqueda expandida
    entity_type     TEXT,               -- person | place | title | date | org
    entity_period   TEXT,               -- ej. 'siglo XVI colonial'
    entity_region   TEXT,               -- ej. 'Nueva España' | 'Virreinato del Perú'

    -- ── Procedencia ─────────────────────────────────────────
    source_doc_id       INTEGER REFERENCES public."Documents"(doc_id),
    source_run_id       UUID,           -- FK implícita a pipeline.pipeline_runs(id)
    added_by_collab_id  INTEGER REFERENCES public."Collaborators"("collab_ID"),
    added_at            TIMESTAMPTZ DEFAULT NOW(),

    -- ── Uso y calidad ────────────────────────────────────────
    retrieval_count     INTEGER DEFAULT 0,      -- veces recuperada por el retriever
    positive_feedback   INTEGER DEFAULT 0,      -- aplicaciones validadas por historiador
    negative_feedback   INTEGER DEFAULT 0,      -- aplicaciones rechazadas

    updated_at          TIMESTAMPTZ DEFAULT NOW()
);

-- Índices para búsqueda por tipo
CREATE INDEX IF NOT EXISTS idx_kb_type
    ON rag.knowledge_base(kb_type);
CREATE INDEX IF NOT EXISTS idx_kb_verified
    ON rag.knowledge_base(verified);
CREATE INDEX IF NOT EXISTS idx_kb_handwriting
    ON rag.knowledge_base(handwriting_type)
    WHERE kb_type = 'abbreviation';
CREATE INDEX IF NOT EXISTS idx_kb_entity_type
    ON rag.knowledge_base(entity_type)
    WHERE kb_type = 'entity';
CREATE INDEX IF NOT EXISTS idx_kb_entity_region
    ON rag.knowledge_base(entity_region)
    WHERE kb_type = 'entity';

-- Índice vectorial HNSW para búsqueda semántica rápida
-- (cosine distance — ajustar m y ef_construction según corpus size)
CREATE INDEX IF NOT EXISTS idx_kb_embedding_hnsw
    ON rag.knowledge_base
    USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);


-- ------------------------------------------------------------
-- rag.kb_build_log
-- Historial de construcciones/reconstrucciones de la KB.
-- Permite saber cuándo se corrió JOB 0 y con qué fuentes.
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS rag.kb_build_log (
    id              UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    kb_type         TEXT        NOT NULL,
    built_at        TIMESTAMPTZ DEFAULT NOW(),
    source_desc     TEXT,                   -- descripción de las fuentes usadas
    n_entries_added INTEGER,
    n_entries_total INTEGER,
    triggered_by    TEXT,                   -- 'job0_initial' | 'reentry_trigger' | 'manual'
    run_id          UUID,                   -- FK implícita a pipeline.pipeline_runs si aplica
    notes           TEXT
);


-- ============================================================
-- VISTAS DE UTILIDAD
-- ============================================================

SET search_path TO pipeline, rag, public;

-- ------------------------------------------------------------
-- Vista: estado actual de la cola de revisión con contexto
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW pipeline.v_review_queue_detail AS
SELECT
    q.id                        AS queue_id,
    q.priority,
    q.status                    AS queue_status,
    q.reason,
    q.n_entities_pending,
    q.assigned_to,
    d.doc_id,
    d.document_internal_id,
    d.title,
    i.inst_collection_project_name AS coleccion,
    t.handwriting_type,
    t.cer_post_histclean,
    t.n_unmatched,
    t.n_partial,
    t.clean_text_url,
    t.reentry_count,
    t.status                    AS doc_status,
    r.batch_name,
    r.started_at                AS run_started_at
FROM pipeline.pipeline_review_queue q
JOIN pipeline.pipeline_document_trace t ON t.id = q.trace_id
JOIN public."Documents"              d ON d.doc_id = q.doc_id
JOIN pipeline.pipeline_runs          r ON r.id = q.run_id
LEFT JOIN public."Instit_Collec_Proj_Key" i
    ON i.inst_coll_proj_id = d.inst_coll_proj_id
ORDER BY
    CASE q.priority WHEN 'high' THEN 1 ELSE 2 END,
    q.n_entities_pending DESC;


-- ------------------------------------------------------------
-- Vista: candidatos para re-entrada (bloqueados + provisionales)
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW pipeline.v_reentry_candidates AS
SELECT
    t.id                    AS trace_id,
    t.doc_id,
    t.run_id                AS original_run_id,
    t.status,
    t.reentry_count,
    t.n_unmatched,
    t.n_partial,
    t.clean_text_url,
    t.handwriting_type,
    t.updated_at            AS last_updated,
    d.document_internal_id,
    d.title
FROM pipeline.pipeline_document_trace t
JOIN public."Documents" d ON d.doc_id = t.doc_id
WHERE t.status IN ('blocked_entities', 'provisional')
  AND t.clean_text_url IS NOT NULL
  AND t.reentry_count < (
      SELECT value::INTEGER
      FROM pipeline.pipeline_config
      WHERE key = 'reentry_max_count'
  )
ORDER BY t.n_unmatched DESC, t.n_partial DESC;


-- ------------------------------------------------------------
-- Vista: resumen de KB-3 — entidades por tipo y estado
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW rag.v_kb3_summary AS
SELECT
    entity_type,
    entity_region,
    COUNT(*)                            AS total_entries,
    SUM(CASE WHEN verified THEN 1 ELSE 0 END)  AS verified_count,
    SUM(CASE WHEN NOT verified THEN 1 ELSE 0 END) AS unverified_count,
    ROUND(AVG(positive_feedback::NUMERIC
              / NULLIF(retrieval_count, 0) * 100), 2) AS avg_precision_pct
FROM rag.knowledge_base
WHERE kb_type = 'entity'
GROUP BY entity_type, entity_region
ORDER BY entity_type, entity_region;


-- ------------------------------------------------------------
-- Vista: cobertura de corpus por ejecución y tipo de letra
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW pipeline.v_run_coverage AS
SELECT
    r.id                    AS run_id,
    r.batch_name,
    r.started_at,
    r.status                AS run_status,
    t.handwriting_type,
    COUNT(*)                AS total_docs,
    SUM(CASE WHEN t.status = 'clean'            THEN 1 ELSE 0 END) AS n_clean,
    SUM(CASE WHEN t.status = 'provisional'      THEN 1 ELSE 0 END) AS n_provisional,
    SUM(CASE WHEN t.status = 'blocked_entities' THEN 1 ELSE 0 END) AS n_blocked,
    SUM(CASE WHEN t.status = 'rejected'         THEN 1 ELSE 0 END) AS n_rejected,
    ROUND(AVG(t.cer_post_histclean), 3)         AS avg_cer_histclean,
    ROUND(AVG(t.bleu_score), 3)                 AS avg_bleu,
    ROUND(AVG(t.entity_preservation), 2)        AS avg_entity_preservation
FROM pipeline.pipeline_runs r
JOIN pipeline.pipeline_document_trace t ON t.run_id = r.id
GROUP BY r.id, r.batch_name, r.started_at, r.status, t.handwriting_type
ORDER BY r.started_at DESC, t.handwriting_type;


-- ============================================================
-- DATOS DE MUESTRA — TABLAS ORIGINALES
-- ============================================================

SET search_path TO public;

INSERT INTO public."Calligraphy_Types" (calligraphy_id, calligraphy_type) VALUES
  (1, 'Cortesana'), (2, 'Redonda'), (3, 'Itálica cursiva'), (4, 'Procesal'),
  (5, 'Impresa'), (6, 'Itálica impresa'), (7, 'Moderna'), (8, 'Pseudorredonda'),
  (9, 'Itálica cursiva?'), (10, 'Gótica'), (11, 'Gótica Libraria'),
  (12, 'Bastarda'), (13, 'Procesal encadenada')
ON CONFLICT DO NOTHING;

INSERT INTO public."Case_Studies" (case_study_id, case_study) VALUES
  (1, 'Social networks'), (2, 'Indigenous slavery'), (3, 'Mobility networks'),
  (4, 'Marcas de afuera'), (5, 'Scientific knoledge'), (6, 'Nahuatl')
ON CONFLICT DO NOTHING;

INSERT INTO public."Collaborators" ("collab_ID", col_name, col_affiliation) VALUES
  (1, 'Patricia Murrieta Flores', 'Lancaster University,University of Oregon'),
  (2, 'Rodrigo Vega Sánchez', 'Lancaster University'),
  (3, 'Francisco Cruz Ríos', 'Archivo General de la Nación'),
  (4, 'Ricardo Valadez Vázquez', NULL),
  (5, 'Amoxcalli', 'Centro de Investigaciones y Estudios Superiores en Antropología Social')
ON CONFLICT DO NOTHING;

INSERT INTO public."Instit_Collec_Proj_Key" (inst_coll_proj_id, inst_collection_project_name) VALUES
  (1, 'Hans P. Kraus'), (2, 'Cempoala_AGN'), (3, 'Amoxcalli'),
  (4, 'Flotas Nueva España'), (5, 'Amox Ben 16th Procesal Simple')
ON CONFLICT DO NOTHING;

INSERT INTO public."Languages" (language_id, language_name) VALUES
  (1, 'Español'), (2, 'Francés'), (3, 'Náhuatl'),
  (4, 'Maya'), (5, 'Latín'), (6, 'Otomí')
ON CONFLICT DO NOTHING;

INSERT INTO public."ML_Models_Key" ("Mod_ID", "Model_Version", "Model") VALUES
  (1, 'Procesal_m2t1_Amox+Cempoala',  'no base model'),
  (2, 'Procesal_m2t2_Amox+Cempoala',  'Amox_Procesal_m1t5'),
  (3, 'Amox_Procesal_m1t1',           'Charlos V / Charles V'),
  (4, 'Amox_Procesal_m1t2',           'Charlos V / Charles V'),
  (5, 'Amox_Procesal_m1t3',           'no base model')
ON CONFLICT DO NOTHING;

INSERT INTO public."Places" (place_id, placename, country) VALUES
  (1,  'Monzón, España',                  'España'),
  (2,  'Portalegre, Portugal',            'Portugal'),
  (3,  'Lisboa, Portugal',                'Portugal'),
  (4,  'San Lorenzo del Escorial, España','España'),
  (5,  'El Pardo (Madrid), España',       'España'),
  (6,  'Ciudad de México, México',        'México'),
  (7,  'Madrid, España',                  'España'),
  (8,  'Aranjuez (Madrid), España',       'España'),
  (9,  'Toledo, España',                  'España'),
  (10, 'Jerez de la Frontera, España',    'España')
ON CONFLICT DO NOTHING;

INSERT INTO public."Types_Of_Documents" (document_type_id, document_type) VALUES
  (1, 'written'), (2, 'pictorial'), (3, 'moderno')
ON CONFLICT DO NOTHING;

INSERT INTO public."Transcription_Availables" (transcription_id, description) VALUES
  (1, 'yes, corrected'), (2, 'yes, in correction'), (3, 'yes, not corrected'),
  (4, 'yes, corrected (INCOMPLETE)'), (5, 'yes, mostly wrong'), (6, 'no')
ON CONFLICT DO NOTHING;

INSERT INTO public."Documents" (doc_id, inst_coll_proj_id, document_internal_id, title, description) VALUES
  (1,   1, 'HPKraus_001',                          'Royal cedula to the audencia of the Island of Española',         'The judges are commanded to permit Francisco de Carrión...'),
  (24,  1, 'HPKraus_122',                          'Deed of sale of land to Bartolomé Dávila',                       'In this document written on vellum, Pero Riquel...'),
  (751, NULL, 'NB_AyerCol_Ms1485_Sahagun_Sermonario_Mexicano', 'Siguense unos sermones de dominicas y de sanctos en lengua mexicana', 'El manuscrito es un semonario...')
ON CONFLICT DO NOTHING;

INSERT INTO public."Document_Calligraphy" (doc_id, calligraphy_id, notes) VALUES
  (2, 2, NULL), (2, 1, NULL), (2, 3, NULL),
  (21, 3, 'cursiva, parece letra de molde (2-4)...'),
  (21, 2, 'cursiva, parece letra de molde (2-4)...')
ON CONFLICT DO NOTHING;

INSERT INTO public."Document_Dates" (doc_id, date_created, year, approximated_date) VALUES
  (1,  '1527-02-15', 1527, NULL),
  (2,  '1533-08-02', 1533, NULL),
  (21, NULL,         NULL, 1600)
ON CONFLICT DO NOTHING;

INSERT INTO public."Document_Languages" (doc_id, language_id, pages) VALUES
  (44, 1, ''), (49, 2, ''), (231, 3, '(p.5-13,15,16)'), (231, 1, '(p.17-28)')
ON CONFLICT DO NOTHING;

INSERT INTO public."Document_Types" (doc_id, type_id) VALUES
  (24, 1), (25, 1), (32, 1), (231, 1), (231, 2)
ON CONFLICT DO NOTHING;

INSERT INTO public."AGI_Doc_Record" (doc_record_id) VALUES (467), (599), (600)
ON CONFLICT DO NOTHING;

INSERT INTO public."LoC_Doc_Record" (doc_id, collection, container, medium) VALUES
  (1, 'Hans P. Kraus', 'BOX 1 REEL 1', '1 leaf'),
  (2, 'Hans P. Kraus', 'BOX 1 REEL 1', '1 leaf'),
  (3, 'Hans P. Kraus', 'BOX 1 REEL 1', '1 leaf')
ON CONFLICT DO NOTHING;

INSERT INTO public."URLs" (doc_id, image_url, "IIIF_manifesto") VALUES
  (1, 'https://hdl.loc.gov/loc.mss/mespk.k00100', 'https://www.loc.gov/item/mss31013-00100/manifest.json'),
  (2, 'https://hdl.loc.gov/loc.mss/mespk.k01000', 'https://www.loc.gov/item/mss31013-01000/manifest.json'),
  (3, 'https://hdl.loc.gov/loc.mss/mespk.k10000', 'https://www.loc.gov/item/mss31013-10000/manifest.json')
ON CONFLICT DO NOTHING;

INSERT INTO public."Transcriptions" ("transcriptionID", document_id, transcribed_lines, transcribed_words) VALUES
  (1, 1, 0, 0), (2, 2, 0, 0), (3, 3, 0, 0)
ON CONFLICT DO NOTHING;

INSERT INTO public."Transcribers" (transcription_id, collab_id) VALUES
  (24, 17), (25, 17), (32, 17);
INSERT INTO public."Reviewers"    (transcription_id, collab_id) VALUES
  (24, 3),  (25, 3),  (32, 3);

INSERT INTO public."Document_Places" (document_id, place_id) VALUES
  (2, 1), (13, 1), (3, 2)
ON CONFLICT DO NOTHING;

INSERT INTO public."Document_Places" (document_id) VALUES (0), (1), (2), (3);

INSERT INTO public."Document_Case_Studies" (doc_id, case_study_id) VALUES
  (766, 1), (767, 1), (768, 2)
ON CONFLICT DO NOTHING;


-- ============================================================
-- NOTAS DE IMPLEMENTACIÓN
-- ============================================================
-- 1. DIMENSIÓN DEL EMBEDDING
--    La columna rag.knowledge_base.embedding usa vector(1536).
--    Si se usa un modelo diferente (ej. sentence-transformers
--    con 768 dims) ajustar antes del primer JOB 0:
--    ALTER TABLE rag.knowledge_base ALTER COLUMN embedding TYPE vector(768);
--
-- 2. BÚSQUEDA SEMÁNTICA (ejemplo de uso del retriever)
--    -- Búsqueda normal KB-3 (umbral alto):
--    SELECT id, canonical_form, entity_type, context_fragment,
--           1 - (embedding <=> $1::vector) AS similarity
--    FROM rag.knowledge_base
--    WHERE kb_type = 'entity'
--      AND verified = TRUE
--      AND (entity_type = $2 OR entity_type IS NULL)
--    ORDER BY embedding <=> $1::vector
--    LIMIT 3;
--
--    -- Búsqueda expandida (umbral bajo, mismo periodo/región):
--    SELECT id, canonical_form, entity_type, context_fragment,
--           1 - (embedding <=> $1::vector) AS similarity
--    FROM rag.knowledge_base
--    WHERE kb_type = 'entity'
--      AND entity_period = $2
--      AND entity_region = $3
--    ORDER BY embedding <=> $1::vector
--    LIMIT 3;
--
-- 3. TRIGGER DE RE-ENTRADA (consulta de referencia)
--    SELECT COUNT(*) AS nuevas_verificadas
--    FROM rag.knowledge_base
--    WHERE kb_type = 'entity'
--      AND verified = TRUE
--      AND added_at > (
--          SELECT MAX(started_at) FROM pipeline.pipeline_runs
--          WHERE is_reentry = TRUE
--      );
--    Si COUNT >= pipeline_config('umbral_reentrada') → lanzar job.
--
-- ============================================================