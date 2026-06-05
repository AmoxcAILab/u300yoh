# Graph Report - .  (2026-06-05)

## Corpus Check
- Large corpus: 4943 files · ~2,651,660 words. Semantic extraction will be expensive (many Claude tokens). Consider running on a subfolder.

## Summary
- 1018 nodes · 1991 edges · 73 communities (63 shown, 10 thin omitted)
- Extraction: 92% EXTRACTED · 8% INFERRED · 0% AMBIGUOUS · INFERRED: 164 edges (avg confidence: 0.55)
- Token cost: 9,800 input · 3,200 output

## Community Hubs (Navigation)
- [[_COMMUNITY_HTR Metrics & Analysis|HTR Metrics & Analysis]]
- [[_COMMUNITY_Python Primitive Types|Python Primitive Types]]
- [[_COMMUNITY_Database Connectivity Layer|Database Connectivity Layer]]
- [[_COMMUNITY_Corpus Report Building|Corpus Report Building]]
- [[_COMMUNITY_Transkribus Layout Analysis|Transkribus Layout Analysis]]
- [[_COMMUNITY_HTR Transcription Trigger|HTR Transcription Trigger]]
- [[_COMMUNITY_Typography Classification|Typography Classification]]
- [[_COMMUNITY_Report HTML Rendering|Report HTML Rendering]]
- [[_COMMUNITY_CRUD Repository Methods|CRUD Repository Methods]]
- [[_COMMUNITY_Collections DB Testing|Collections DB Testing]]
- [[_COMMUNITY_Ground Truth Registration|Ground Truth Registration]]
- [[_COMMUNITY_Annotation Sync|Annotation Sync]]
- [[_COMMUNITY_Review Sampling & Allocation|Review Sampling & Allocation]]
- [[_COMMUNITY_HTML Report Formatting|HTML Report Formatting]]
- [[_COMMUNITY_Knowledge Base Building|Knowledge Base Building]]
- [[_COMMUNITY_Image Preprocessing|Image Preprocessing]]
- [[_COMMUNITY_Review Pool Management|Review Pool Management]]
- [[_COMMUNITY_Collection Registration|Collection Registration]]
- [[_COMMUNITY_Issue Logging Utilities|Issue Logging Utilities]]
- [[_COMMUNITY_File IO Utilities|File I/O Utilities]]
- [[_COMMUNITY_Collection Import|Collection Import]]
- [[_COMMUNITY_Database Backup|Database Backup]]
- [[_COMMUNITY_HTR Evaluation Metrics|HTR Evaluation Metrics]]
- [[_COMMUNITY_Annotation Export|Annotation Export]]
- [[_COMMUNITY_Calligraphy CNN Model|Calligraphy CNN Model]]
- [[_COMMUNITY_Pipeline Observability Tables|Pipeline Observability Tables]]
- [[_COMMUNITY_HTR Cleaning Steps 2 & 3|HTR Cleaning Steps 2 & 3]]
- [[_COMMUNITY_HTR Cleaning Step 1 & Tags|HTR Cleaning Step 1 & Tags]]
- [[_COMMUNITY_PDF Metadata Extraction|PDF Metadata Extraction]]
- [[_COMMUNITY_RAG Correction Engine|RAG Correction Engine]]
- [[_COMMUNITY_HTR-GT Character Alignment|HTR-GT Character Alignment]]
- [[_COMMUNITY_HTR Cleaning Pipeline Concepts|HTR Cleaning Pipeline Concepts]]
- [[_COMMUNITY_Core Database Tables|Core Database Tables]]
- [[_COMMUNITY_Vector Store Embeddings|Vector Store Embeddings]]
- [[_COMMUNITY_HTR-GT Split Preparation|HTR-GT Split Preparation]]
- [[_COMMUNITY_Issue Logging|Issue Logging]]
- [[_COMMUNITY_Project Overview & Archives|Project Overview & Archives]]
- [[_COMMUNITY_NLP Models & Lexicons|NLP Models & Lexicons]]
- [[_COMMUNITY_Statistical Distribution Metrics|Statistical Distribution Metrics]]
- [[_COMMUNITY_RAG Gradio App|RAG Gradio App]]
- [[_COMMUNITY_Corpus Loader|Corpus Loader]]
- [[_COMMUNITY_Vector Retrieval|Vector Retrieval]]
- [[_COMMUNITY_Database Schema Foundations|Database Schema Foundations]]
- [[_COMMUNITY_Issue ID Assignment|Issue ID Assignment]]
- [[_COMMUNITY_Quality Pipeline Steps 5-7|Quality Pipeline Steps 5-7]]
- [[_COMMUNITY_Character Normalisation|Character Normalisation]]
- [[_COMMUNITY_Posthoc Tag Analysis|Posthoc Tag Analysis]]
- [[_COMMUNITY_Operations & Metadata Format|Operations & Metadata Format]]
- [[_COMMUNITY_Decolonial NLP Research|Decolonial NLP Research]]
- [[_COMMUNITY_Project Bootstrap|Project Bootstrap]]
- [[_COMMUNITY_Documents DB Testing|Documents DB Testing]]
- [[_COMMUNITY_Training Corpus Data|Training Corpus Data]]
- [[_COMMUNITY_Observability Architecture|Observability Architecture]]
- [[_COMMUNITY_Data Ingestion Steps 1-4|Data Ingestion Steps 1-4]]
- [[_COMMUNITY_Clean Modern Slurm Job|Clean Modern Slurm Job]]
- [[_COMMUNITY_Text Diagnostics|Text Diagnostics]]
- [[_COMMUNITY_Match Diagnostics|Match Diagnostics]]
- [[_COMMUNITY_Developer Reset Utility|Developer Reset Utility]]
- [[_COMMUNITY_Historical Clean Slurm Job|Historical Clean Slurm Job]]
- [[_COMMUNITY_HTR Transcription Slurm Job|HTR Transcription Slurm Job]]
- [[_COMMUNITY_Typography Slurm Job|Typography Slurm Job]]
- [[_COMMUNITY_Abbreviation RAG KB|Abbreviation RAG KB]]
- [[_COMMUNITY_Knowledge Base Module|Knowledge Base Module]]
- [[_COMMUNITY_Collection Import Entry|Collection Import Entry]]
- [[_COMMUNITY_RAG Schema Migration|RAG Schema Migration]]
- [[_COMMUNITY_Pipeline Entry Checkpoint|Pipeline Entry Checkpoint]]

## God Nodes (most connected - your core abstractions)
1. `Operations` - 68 edges
2. `Images` - 47 edges
3. `get_conn()` - 45 edges
4. `Documents` - 38 edges
5. `Collections` - 35 edges
6. `build_corpus_report()` - 31 edges
7. `load_json_if_exists()` - 23 edges
8. `str` - 22 edges
9. `HTR` - 21 edges
10. `check_connection()` - 20 edges

## Surprising Connections (you probably didn't know these)
- `Abbreviation Lexicon (UNAM Dictionary of New Spain Abbreviations)` --semantically_similar_to--> `Table: public.abbreviations`  [INFERRED] [semantically similar]
  pipeline/htr_nlp/htr_nlp.md → database/schema.sql
- `CER media corpus — 0.1667 (entrenamiento, New Spain Fleets)` --semantically_similar_to--> `Métricas de calidad — CER, WER, BLEU, ChrF++`  [INFERRED] [semantically similar]
  outputs/data_descriptive_analysis/corpus_report.html → observability.md
- `Tag Group S3: Historical Orthographic Patterns` --semantically_similar_to--> `HistClean-SpA: Cleaning Model for Historical Spanish`  [INFERRED] [semantically similar]
  pipeline/htr_descriptive_analysis/pre/schemas_and_manifests/tag_schema.json → pipeline/htr_nlp/htr_nlp.md
- `Tabla operations — Registro central de acciones del pipeline` --semantically_similar_to--> `public.operations — Observabilidad central del pipeline`  [INFERRED] [semantically similar]
  database/data_base.md → README.md
- `KB-2 — Knowledge Base de pares de modernización (RAG-2)` --semantically_similar_to--> `Tabla modernization_pairs — Pares GT → versión moderna`  [INFERRED] [semantically similar]
  observability.md → database/data_base.md

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **HTR Pipeline — Observabilidad y trazabilidad de documentos históricos** — u300yoh_readme_htr_pipeline, observability_observability_pipeline_document_trace, data_base_data_base_operations_table, observability_observability_routing_carril [INFERRED 0.85]
- **Knowledge Bases RAG para corrección y modernización HTR** — observability_observability_kb1_abbreviations, observability_observability_kb2_modernization, observability_observability_kb3_entities [EXTRACTED 0.95]
- **HTR Cleaning — Detección estructurada en 3 niveles de análisis** — htr_cleaning_htr_cleaning_step1, htr_cleaning_htr_cleaning_step2, htr_cleaning_htr_cleaning_step3 [EXTRACTED 0.95]
- **HTR Cleaning and Modernization Pipeline (Steps 5-6, HistClean-SpA, Hist2Mod-SpA, hist_clean, clean_modern tables)** — pipeline_pipeline_step5_historical_clean, pipeline_pipeline_step6_modernization, htr_nlp_histclean_spa, htr_nlp_hist2mod_spa, schema_sql_public_hist_clean, schema_sql_public_clean_modern [INFERRED 0.85]
- **Pipeline Observability via Operations Log (principle, table, views, pipeline steps)** — pipeline_pipeline_observability_principle, schema_sql_public_operations, schema_sql_v_pipeline_status, schema_sql_v_quality_metrics, schema_sql_public_descriptive_analysis [EXTRACTED 0.95]
- **HTR Quality Evaluation (metrics, tag schema, descriptive analysis, NLP models)** — pipeline_pipeline_quality_metrics, tag_schema_htr_error_tags, schema_sql_public_descriptive_analysis, htr_nlp_histclean_spa [INFERRED 0.75]

## Communities (73 total, 10 thin omitted)

### Community 0 - "HTR Metrics & Analysis"
Cohesion: 0.08
Nodes (45): Any, str, bigram_confusions_by_style(), boundary_norm(), build_doc_issue_lookup(), char_confusions_by_style(), compute_doc_metrics(), compute_drift_from_doc_issues() (+37 more)

### Community 1 - "Python Primitive Types"
Cohesion: 0.08
Nodes (42): int, str, bool, float, int, str, bool, float (+34 more)

### Community 2 - "Database Connectivity Layer"
Cohesion: 0.07
Nodes (28): float, int, str, _build_dsn(), DescriptiveAnalysis, OperationTypes, PipelineStatus, database/migration/db.py ──────────────────────── API de acceso a la BD local (P (+20 more)

### Community 3 - "Corpus Report Building"
Cohesion: 0.14
Nodes (39): alignment_ops_by_style(), build_corpus_report(), build_line_length_lookup(), cer_contributing_words_by_style(), char_position_distribution_by_style(), compute_geometry_by_style(), fmt_count_pct(), fmt_int() (+31 more)

### Community 4 - "Transkribus Layout Analysis"
Cohesion: 0.09
Nodes (35): _get_session_cookie(), _get_transkribus_collection_id(), main(), _poll_job_status(), bool, int, Path, str (+27 more)

### Community 5 - "HTR Transcription Trigger"
Cohesion: 0.08
Nodes (35): _download_htr_text(), _get_session_cookie(), main(), _poll_job(), int, Path, str, data_ingestion/trigger_htr_transcription.py ──────────────────────────────────── (+27 more)

### Community 6 - "Typography Classification"
Cohesion: 0.09
Nodes (30): classify_typography(), _classify_with_gradio(), _classify_with_local_model(), main(), float, Path, str, data_ingestion/typography_classification.py ──────────────────────────────────── (+22 more)

### Community 7 - "Report HTML Rendering"
Cohesion: 0.12
Nodes (32): build_corpus_report(), concentration_rows(), confusion_rows(), corpus_distribution_rows(), doc_block_rows(), geometry_rows(), issue_by_style_rows(), issue_stage_rows() (+24 more)

### Community 8 - "CRUD Repository Methods"
Cohesion: 0.09
Nodes (10): Models, int, str, Inserta un documento y registra la operación document_registered.         Devuel, Inserta una imagen y registra image_registered.         image_type: 'original' |, Inserta un registro HTR y registra htr_available.         Devuelve el htr_id asi, Inserta un registro de ground_truth y registra ground_truth_registered., Inserta una colección y registra la operación collection_registered.         Dev (+2 more)

### Community 9 - "Collections DB Testing"
Cohesion: 0.08
Nodes (9): Collections, CRUD para public.collections., conn(), db_available(), database/tests/crud_operations_test.py ────────────────────────────────────────, TestCollections, TestHTR, TestImages (+1 more)

### Community 10 - "Ground Truth Registration"
Cohesion: 0.12
Nodes (23): main(), int, Path, data_ingestion/register_ground_truth.py ────────────────────────────────────────, Registra archivos ground_truth para una colección.     Devuelve un resumen con c, register_ground_truth(), GroundTruth, HTR (+15 more)

### Community 11 - "Annotation Sync"
Cohesion: 0.18
Nodes (25): _get_or_create_entity_type_id(), _get_or_create_error_type_id(), _get_or_create_expansion_type_id(), _load_processed_registry(), main(), process_abbreviations(), process_entities(), process_errors() (+17 more)

### Community 12 - "Review Sampling & Allocation"
Cohesion: 0.16
Nodes (24): DataFrame, int, Path, str, _allocate_stage_quotas(), _bin_counts(), load_tracked_issue_ids(), print_stage_distribution() (+16 more)

### Community 13 - "HTML Report Formatting"
Cohesion: 0.12
Nodes (24): bool, float, int, object, str, csv_ready_rows(), f_float(), f_pp() (+16 more)

### Community 14 - "Knowledge Base Building"
Cohesion: 0.19
Nodes (22): build_abbreviations(), build_document_knowledge(), build_entities(), build_error_patterns(), build_knowledge_base(), _clear_kb_type(), _embed_texts(), _get_embedding_model() (+14 more)

### Community 15 - "Image Preprocessing"
Cohesion: 0.16
Nodes (21): _apply_clahe(), _clahe_tile(), main(), preprocess_image(), float, int, data_ingestion/image_pre_processing.py ─────────────────────────────────────── P, Ecualización de histograma adaptativa por celdas (CLAHE simplificado).     Traba (+13 more)

### Community 16 - "Review Pool Management"
Cohesion: 0.13
Nodes (16): allocate_reviews(), allocate_reviews.py  Allocate sampled issues to individual reviewers.  Reads, build_corpus_report.py  Script to generate a full interactive corpus diagnosti, build_review_pool(), _normalise_issue(), build_review_pool.py  Builds the review pool used for manual validation.  Ma, Convert issue dict to the canonical review schema.      Handles differences be, main() (+8 more)

### Community 17 - "Collection Registration"
Cohesion: 0.16
Nodes (19): main(), int, Path, str, data_ingestion/register_collection.py ────────────────────────────────────── Reg, Lee el CSV de metadatos de la colección.     Devuelve {document_filename: {colum, Registra una colección completa desde un directorio local.     Devuelve un resum, _read_metadata_csv() (+11 more)

### Community 18 - "Issue Logging Utilities"
Cohesion: 0.17
Nodes (20): int, Path, str, issues_json_path(), Adds the HTR filename to the per-document log of JSON issues., Read UTF-8 text file., read_text(), _compute_line_offsets() (+12 more)

### Community 19 - "File I/O Utilities"
Cohesion: 0.16
Nodes (19): bool, int, Path, str, ensure_parent(), index_htr_files_by_style(), index_txt_files(), issues_txt_path() (+11 more)

### Community 20 - "Collection Import"
Cohesion: 0.14
Nodes (17): import_collection(), main(), int, Path, data_ingestion/import_collection.py ──────────────────────────────────── Descarg, Importa imágenes de una fuente externa hacia raw_collections_images/.     Regist, db_available(), data_ingestion/tests/import_collection_test.py ───────────────────────────────── (+9 more)

### Community 21 - "Database Backup"
Cohesion: 0.14
Nodes (18): create_backup(), main(), int, Path, str, Ejecuta pg_dump y guarda el archivo en output_dir.      Devuelve dict con backup, db_available(), database/tests/create_backup_test.py ────────────────────────────────────── Test (+10 more)

### Community 22 - "HTR Evaluation Metrics"
Cohesion: 0.18
Nodes (11): bool, float, int, str, Evaluator, evaluator.py ──────────── Métricas de calidad para las correcciones del sistem, Evalúa el sistema sobre una lista de pares con groundtruth.         Retorna mét, Character Error Rate (Levenshtein a nivel carácter). (+3 more)

### Community 23 - "Annotation Export"
Cohesion: 0.21
Nodes (15): export_abbreviations(), export_collection(), export_documents(), export_entities(), export_errors(), main(), int, Path (+7 more)

### Community 24 - "Calligraphy CNN Model"
Cohesion: 0.17
Nodes (7): CaligrafiaCRNN, CaligrafiaPredictor, get_device(), Predicción desde objeto PIL Image (para Flask), Predicción desde ruta de archivo, Redimensiona preservando la proporción original:       1. Escala hasta que alto, ResizeWithPad

### Community 25 - "Pipeline Observability Tables"
Cohesion: 0.15
Nodes (15): Aplicación Anotador — Interfaz de revisión humana, KB-3 — Knowledge Base de entidades históricas verificadas (NER + RAG-3), PC-3 — Punto de control post-HistClean-SpA (enrutamiento carril), PC-5 — Punto de control salida final / validación corpus, pipeline_config — Umbrales configurables del pipeline, pipeline_document_trace — Tabla central de observabilidad por documento, pipeline_human_review — Resultados de revisión humana, pipeline_review_queue — Cola de revisión priorizada (+7 more)

### Community 26 - "HTR Cleaning Steps 2 & 3"
Cohesion: 0.20
Nodes (13): Any, _load_step1_spans(), run_step2.py  Pipeline stage for Step 2: Runs character-level HTR-GT alignment, Reload Step 1 spans from issues.json using tag_schema as the source of truth., run_step2(), _load_step1_and_step2_spans(), run_step3.py  Pipeline stage for Step 3: Runs linguistic / paleographic heuris, Load Step 1 and Step 2 spans from logs in a single pass.      Returns: (+5 more)

### Community 27 - "HTR Cleaning Step 1 & Tags"
Cohesion: 0.24
Nodes (12): Path, str, run_step1.py  Pipeline Stage 1: Runs basic preprocessing and normalisation of, run_step1(), tag_rules.py  Regex-based rules for transcription error tagging in steps 1 and, generate_all_outputs(), plot_step_summary(), visualise.py  Utilities for plotting pipeline outputs  Supports:  Step 1: (+4 more)

### Community 28 - "PDF Metadata Extraction"
Cohesion: 0.26
Nodes (13): build_metadata(), convert_date(), extract_fields(), main(), _normalize_label(), normalize_rango_fojas(), Path, str (+5 more)

### Community 29 - "RAG Correction Engine"
Cohesion: 0.26
Nodes (6): int, str, RAGCorrector, rag_corrector.py ──────────────── Núcleo del sistema RAG.    1. Detecta posi, Corrige un texto HTR usando RAG.          Retorna dict con:           correct, Detecta formas modernas que NO deberían modernizarse.

### Community 30 - "HTR-GT Character Alignment"
Cohesion: 0.23
Nodes (12): bool, int, str, align_and_tag(), compute_line_offsets(), find_line_number(), alignment.py (legacy)  Utilities to achieve character-level alignment for Step, Compute global character offsets for the start of each line.      Returns a li (+4 more)

### Community 31 - "HTR Cleaning Pipeline Concepts"
Cohesion: 0.18
Nodes (12): Clasificacion API — Clasificador tipográfico Gradio (HuggingFace Spaces), Tipos de caligrafía — Encadenada, Itálica Cursiva, Procesal, Redonda, New Spain Fleets — Corpus de referencia del pipeline, Sin auto-corrección — Solo detección y log para revisión humana, HTR Cleaning Pipeline — Detección de anomalías en 3 pasos, posthoc_analysis.py — Análisis de solapamiento entre pasos, run_split.py — Emparejamiento HTR-GT y split estratificado, Step 1 — Errores básicos de transcripción (whitespace, puntuación, Unicode) (+4 more)

### Community 32 - "Core Database Tables"
Cohesion: 0.22
Nodes (11): Tabla clean_modern — Versión modernizada, Tabla descriptive_analysis — Métricas de calidad HTR, Tabla ground_truth — Transcripción corregida manualmente (gold), Tabla hist_clean — Versión histórica normalizada, Tabla htr — Transcripciones automáticas HTR, Tabla modernization_pairs — Pares GT → versión moderna, Arquitectura de notas — Notas como entidades independientes con junctions, Esquema de base de datos PostgreSQL — Modelo ER completo (+3 more)

### Community 33 - "Vector Store Embeddings"
Cohesion: 0.20
Nodes (7): str, Documents, EmbeddingFunction, Embeddings, MT5EmbeddingFunction, vector_store.py ─────────────── Indexa pares HTR/GT en ChromaDB usando embeddi, Usa el encoder de mt5 fine-tuneado con pares HTR/GT para generar embeddings.

### Community 34 - "HTR-GT Split Preparation"
Cohesion: 0.27
Nodes (10): Path, str, _basename(), build_htr_prefix_index(), ensure_raw_data(), run_split.py  Script prepares for HTR cleaning by:  - Downloading + unzippin, Extract pairing key from filename.      Pairs are identified by removing the t, Builds an index mapping every possible left-prefix of an HTR stem to the HTR fil (+2 more)

### Community 35 - "Issue Logging"
Cohesion: 0.25
Nodes (10): Any, Path, str, format_issue_for_text(), is_duplicate(), log_issue(), logging.py  Helpers for recording transcription issues.  Two representations, Check whether an identical issue has already been logged.      Two issues are (+2 more)

### Community 36 - "Project Overview & Archives"
Cohesion: 0.22
Nodes (10): Estados de documento — Flujo new → nlp_ready, Archivo General de Indias (AGI), Archivo General de la Nación (AGN), AmoxcAILab u300yoh Project, HTR Pipeline (Manuscritos Históricos XVI-XVIII), Nix Environment (amoxcailab_flake.nix), PostgreSQL + pgvector — Backend vectorial y observabilidad, Schmidt Sciences Cluster (GPU + Slurm) (+2 more)

### Community 37 - "NLP Models & Lexicons"
Cohesion: 0.20
Nodes (10): Abbreviation Lexicon (UNAM Dictionary of New Spain Abbreviations), HistClean-SpA: Cleaning Model for Historical Spanish, QLoRA Fine-Tuning Strategy for Historical Corpora, Annotation Flow: GitHub to DB and Back, Table: public.abbreviations, Table: public.entities (Named Entities), HTR Error Tag Schema (S1/S2/S3 Classification), Tag Group S1: Whitespace and Punctuation Errors (+2 more)

### Community 38 - "Statistical Distribution Metrics"
Cohesion: 0.29
Nodes (10): float, int, aggregate_style_metrics(), gini(), lorenz_points(), percentile(), Build Lorenz-curve coordinates for a sequence of document burdens., Return a simple percentile from a sorted list using the same deterministic (+2 more)

### Community 39 - "RAG Gradio App"
Cohesion: 0.31
Nodes (8): bool, int, str, add_to_corpus(), cambiar_embedding(), corregir(), evaluar_par(), app.py ────── Interfaz web Gradio para el sistema RAG de corrección de castell

### Community 40 - "Corpus Loader"
Cohesion: 0.36
Nodes (4): str, CorpusLoader, corpus_loader.py ──────────────── Carga pares (HTR, groundtruth) desde disco., Detecta formato y carga todos los pares disponibles.

### Community 41 - "Vector Retrieval"
Cohesion: 0.33
Nodes (5): int, Indexa los pares HTR/GT. Cada fragmento se almacena con:           - document, Recupera los k pares más similares al texto HTR de consulta.         Retorna li, Elimina y recrea la colección (útil para re-indexar desde cero)., VectorStore

### Community 42 - "Database Schema Foundations"
Cohesion: 0.28
Nodes (9): Flotas Original Database Backup (AGI, Calligraphy data), Original Flotas Database Schema (Legacy), Pipeline Step 0: Register Collection, AmoxcAILab PostgreSQL Database Schema, pgvector Extension for Embedding Storage, Table: public.collections, Table: public.documents, Table: public.images (+1 more)

### Community 43 - "Issue ID Assignment"
Cohesion: 0.25
Nodes (7): assign_issue_ids_all_logs(), assign_issue_ids.py  Attach unique, deterministic IDs to all issues after Step, int, str, generate_issue_id(), issue_ids.py  Utility functions for issuing IDs.  These IDs are stable acros, Deterministic hash-based issue ID.      Parameters:         doc_id (str): Doc

### Community 44 - "Quality Pipeline Steps 5-7"
Cohesion: 0.31
Nodes (9): Pipeline Quality Metrics (CER, WER, BLEU, ChrF++), Pipeline Step 5: Historical Cleaning (Slurm GPU), Pipeline Step 6: Modernization (Slurm GPU), Pipeline Step 7: Human Review, Table: public.clean_modern, Table: public.descriptive_analysis, Table: public.hist_clean, View: public.v_quality_metrics (+1 more)

### Community 45 - "Character Normalisation"
Cohesion: 0.36
Nodes (7): bool, str, normalise_char(), normalise_pair(), normalisation.py  Utility used to clean up confusion matrices by removing cer, Normalise a single character for analytical comparison.      Steps:     - Rep, Normalise a pair of aligned characters.

### Community 46 - "Posthoc Tag Analysis"
Cohesion: 0.32
Nodes (7): str, count_tags_from_logs(), posthoc_analysis.py  Posthoc analytical utilities to assess overlap between pi, Sum counts in a dict-of-dicts structure., Count total issues whose tag starts with prefix (S1, S2, S3),     then aggregat, run_posthoc_analysis(), sum_nested_counts()

### Community 47 - "Operations & Metadata Format"
Cohesion: 0.29
Nodes (7): Tabla operations — Registro central de acciones del pipeline, Tabla collections — Colecciones documentales, Tabla documents — Documentos individuales, Columnas dinámicas — ALTER TABLE para campos desconocidos en metadata, Formato .metadata — Archivos de configuración de colecciones y documentos, register_collection.py — Registro de colecciones y documentos, public.operations — Observabilidad central del pipeline

### Community 48 - "Decolonial NLP Research"
Cohesion: 0.29
Nodes (7): AGN Fondos Marina and Tierras (35,000+ documents), Decolonial AI for Latin American Colonial Archives, Dual-Model Pipeline: Clean Then Modernise, Hist2Mod-SpA: Standardisation Model Historical-to-Modern Spanish, HTR NLP Project: Unlocking 300 Years of Colonial Spanish, Real Data: Colonial Archives as AI Training Resource, Relaciones Geográficas Corpus (12 volumes)

### Community 49 - "Project Bootstrap"
Cohesion: 0.48
Nodes (6): Path, str, main(), mkdir(), bootstrap.py  Project initialisation script for the HTR cleaning pipeline., write_if_missing()

### Community 51 - "Training Corpus Data"
Cohesion: 0.33
Nodes (6): HTR/Ground-Truth Aligned Document Pairs, NSF-RAG-Codex Corpus (HTR/GT Pairs, New Spain Fleets), Corpus HTR Encadenada (GitHub patymurrieta), Corpus Ground Truths (GitHub patymurrieta), Corpus HTR Procesal (GitHub patymurrieta), HTR Corpus ZIP Manifest (New Spain Fleets)

### Community 52 - "Observability Architecture"
Cohesion: 0.33
Nodes (6): Pipeline Observability Schema (Migration), AmoxcAILab Processing Pipeline, Observability Principle: Everything Is an Operation, Operation Types Catalog, Table: public.operations (Central Pipeline Log), View: public.v_pipeline_status

### Community 53 - "Data Ingestion Steps 1-4"
Cohesion: 0.33
Nodes (6): Pipeline Step 1: Image Preprocessing, Pipeline Step 2: Layout Analysis (Transkribus), Pipeline Step 3: Typography Classification (Slurm GPU), Pipeline Step 4: HTR Transcription (Transkribus), Table: public.htr, Table: public.layouts (Transkribus Layout XML)

### Community 54 - "Clean Modern Slurm Job"
Cohesion: 0.67
Nodes (3): job_clean_modern.sh script, check_prerequisite(), PYTHONPATH

### Community 57 - "Developer Reset Utility"
Cohesion: 0.50
Nodes (3): delete.py  Developer utility for resetting during testing.  This removes ONL, Delete all generated runtime folders so the pipeline can be rerun from scratch., reset_project_data()

### Community 62 - "Abbreviation RAG KB"
Cohesion: 0.67
Nodes (3): Tabla abbreviations — Abreviaturas detectadas, NSF RAG Codex — RAG para corrección de output HTR (Gradio/HuggingFace), KB-1 — Knowledge Base de abreviaturas para RAG

## Knowledge Gaps
- **68 isolated node(s):** `int`, `bool`, `int`, `Documents`, `Embeddings` (+63 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **10 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Operations` connect `Image Preprocessing` to `Database Connectivity Layer`, `Transkribus Layout Analysis`, `HTR Transcription Trigger`, `Typography Classification`, `CRUD Repository Methods`, `Collections DB Testing`, `Ground Truth Registration`, `Annotation Sync`, `Knowledge Base Building`, `Collection Registration`, `Documents DB Testing`, `Collection Import`, `Database Backup`, `Annotation Export`?**
  _High betweenness centrality (0.051) - this node is a cross-community bridge._
- **Why does `get_conn()` connect `Image Preprocessing` to `Database Connectivity Layer`, `Transkribus Layout Analysis`, `HTR Transcription Trigger`, `Typography Classification`, `Collections DB Testing`, `Ground Truth Registration`, `Annotation Sync`, `Knowledge Base Building`, `Collection Registration`, `Collection Import`, `Database Backup`, `Annotation Export`?**
  _High betweenness centrality (0.037) - this node is a cross-community bridge._
- **Why does `build_corpus_report()` connect `Report HTML Rendering` to `HTR Metrics & Analysis`, `Statistical Distribution Metrics`, `HTML Report Formatting`, `Review Pool Management`, `File I/O Utilities`, `HTR Cleaning Steps 2 & 3`?**
  _High betweenness centrality (0.025) - this node is a cross-community bridge._
- **Are the 42 inferred relationships involving `Operations` (e.g. with `int` and `str`) actually correct?**
  _`Operations` has 42 INFERRED edges - model-reasoned connections that need verification._
- **Are the 28 inferred relationships involving `Images` (e.g. with `float` and `int`) actually correct?**
  _`Images` has 28 INFERRED edges - model-reasoned connections that need verification._
- **Are the 20 inferred relationships involving `Documents` (e.g. with `int` and `Path`) actually correct?**
  _`Documents` has 20 INFERRED edges - model-reasoned connections that need verification._
- **Are the 18 inferred relationships involving `Collections` (e.g. with `int` and `Path`) actually correct?**
  _`Collections` has 18 INFERRED edges - model-reasoned connections that need verification._