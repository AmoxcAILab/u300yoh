"""
database/migration/db.py
────────────────────────
API de acceso a la BD local (PostgreSQL + pgvector).
Lee las variables de entorno exportadas por amoxcailab_flake.nix.

Toda acción sobre el sistema se registra como una fila en public.operations
más un registro en la tabla de unión de la entidad afectada.

Variables de entorno (seteadas por el flake):
  HTR_DB_URL             postgresql://user@/htr_pipeline?host=/path/run&port=5433
  HTR_PGHOST / HTR_PGRUN directorio del socket Unix
  HTR_PGPORT             puerto (default 5433)
  HTR_PGDB               nombre de la base de datos
  HTR_PGUSER             usuario
  HTR_COLLABORATOR_ID    ID del colaborador activo (opcional)

Uso típico:
  from database.migration.db import get_conn, Operations, DescriptiveAnalysis

  with get_conn() as conn:
      op_id = Operations.record_and_link(
          conn,
          operation_type="collection_registered",
          entity="collection",
          entity_id=collection_id,
      )
"""

import os
import json
from contextlib import contextmanager
from datetime import datetime, timezone
from typing import Optional

import psycopg2
import psycopg2.extras

psycopg2.extras.register_uuid()


# ──────────────────────────────────────────────────────────────
# CONEXIÓN
# ──────────────────────────────────────────────────────────────

def _build_dsn() -> str:
    """
    Construye el DSN desde variables de entorno del flake.
    Prioriza HTR_DB_URL si está definida; si no, construye desde partes.
    """
    url = os.environ.get("HTR_DB_URL")
    if url:
        return url

    host = os.environ.get("HTR_PGRUN",
           os.environ.get("PGHOST", "/tmp"))
    port = os.environ.get("HTR_PGPORT",
           os.environ.get("PGPORT", "5433"))
    db   = os.environ.get("HTR_PGDB",
           os.environ.get("PGDATABASE", "htr_pipeline"))
    user = os.environ.get("HTR_PGUSER",
           os.environ.get("PGUSER", os.environ.get("USER", "postgres")))

    return f"postgresql://{user}@/{db}?host={host}&port={port}"


@contextmanager
def get_conn(autocommit: bool = False):
    """
    Context manager que devuelve una conexión psycopg2.
    Hace rollback automático si hay excepción; commit si no.

    Uso:
        with get_conn() as conn:
            op_id = Operations.record_and_link(conn, ...)
    """
    dsn  = _build_dsn()
    conn = psycopg2.connect(dsn, cursor_factory=psycopg2.extras.RealDictCursor)
    conn.autocommit = autocommit
    try:
        yield conn
        if not autocommit:
            conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def check_connection() -> bool:
    """Verifica que la BD está accesible. Devuelve True/False."""
    try:
        with get_conn() as conn:
            cur = conn.cursor()
            cur.execute("SELECT 1")
        return True
    except Exception as e:
        print(f"✗ No se pudo conectar a la BD: {e}")
        return False


# ──────────────────────────────────────────────────────────────
# RESOLUCIÓN DE COLLABORATOR ID
# ──────────────────────────────────────────────────────────────

def resolve_collaborator_id(conn, collaborator_id: Optional[int] = None) -> Optional[int]:
    """
    Resuelve el collaborator_id activo con este orden de precedencia:
    1. El valor pasado explícitamente
    2. Variable de entorno HTR_COLLABORATOR_ID
    3. Buscar por $USER en public.collaborators (y crear si no existe)
    4. None si ninguna opción es posible
    """
    if collaborator_id is not None:
        return collaborator_id

    env_id = os.environ.get("HTR_COLLABORATOR_ID")
    if env_id:
        return int(env_id)

    username = os.environ.get("USER") or os.environ.get("USERNAME")
    if not username:
        return None

    cur = conn.cursor()
    cur.execute(
        "SELECT collaborator_id FROM public.collaborators WHERE collaborator_name = %(name)s",
        {"name": username},
    )
    row = cur.fetchone()
    if row:
        return row["collaborator_id"]

    # Crear el colaborador automáticamente
    cur.execute(
        "INSERT INTO public.collaborators (collaborator_name) VALUES (%(name)s) "
        "RETURNING collaborator_id",
        {"name": username},
    )
    row = cur.fetchone()
    return row["collaborator_id"] if row else None


# ──────────────────────────────────────────────────────────────
# OPERATION TYPES — cache de IDs por nombre
# ──────────────────────────────────────────────────────────────

class OperationTypes:
    """Cache en memoria de operation_type_id por nombre."""

    _cache: dict[str, int] = {}

    @classmethod
    def get_id(cls, conn, operation_type: str) -> int:
        """
        Devuelve el operation_type_id correspondiente al nombre.
        Lanza ValueError si el tipo no existe en la BD.
        """
        if operation_type in cls._cache:
            return cls._cache[operation_type]

        cur = conn.cursor()
        cur.execute(
            "SELECT operation_type_id FROM public.operation_types "
            "WHERE operation_type = %(operation_type)s",
            {"operation_type": operation_type},
        )
        row = cur.fetchone()
        if row is None:
            raise ValueError(
                f"Tipo de operación desconocido: '{operation_type}'. "
                f"Verifica el catálogo en public.operation_types."
            )
        cls._cache[operation_type] = row["operation_type_id"]
        return cls._cache[operation_type]

    @classmethod
    def clear_cache(cls):
        """Limpia el cache (útil en tests)."""
        cls._cache.clear()


# ──────────────────────────────────────────────────────────────
# OPERATIONS — registro central de todas las acciones
# ──────────────────────────────────────────────────────────────

# Mapeo de nombre de entidad a tabla de unión y columna FK
_ENTITY_JUNCTION = {
    "collection": ("public.collections_operations", "collection_id"),
    "document":   ("public.documents_operations",   "document_id"),
    "image":      ("public.images_operations",       "image_id"),
    "htr":        ("public.htr_operations",          "htr_id"),
    "model":      ("public.models_operations",       "model_id"),
}


class Operations:
    """Registro central de operaciones del pipeline."""

    @staticmethod
    def record(
        conn,
        operation_type: str,
        collaborator_id: Optional[int] = None,
        slurm_job_id: Optional[str] = None,
        transkribus_job_id: Optional[str] = None,
        status: str = "completed",
    ) -> int:
        """
        Inserta una fila en public.operations y devuelve el operation_id.

        Para operaciones sin entidad específica (system-level), úsalo directamente.
        Para operaciones sobre una entidad, preferir record_and_link().
        """
        collaborator_id = resolve_collaborator_id(conn, collaborator_id)
        operation_type_id = OperationTypes.get_id(conn, operation_type)

        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO public.operations (
                operation_type_id, collaborator_id,
                slurm_job_id, transkribus_job_id, status
            ) VALUES (
                %(operation_type_id)s, %(collaborator_id)s,
                %(slurm_job_id)s, %(transkribus_job_id)s, %(status)s
            )
            RETURNING operation_id
            """,
            {
                "operation_type_id":  operation_type_id,
                "collaborator_id":    collaborator_id,
                "slurm_job_id":       slurm_job_id,
                "transkribus_job_id": transkribus_job_id,
                "status":             status,
            },
        )
        return cur.fetchone()["operation_id"]

    @staticmethod
    def link(conn, operation_id: int, entity: str, entity_id: int) -> None:
        """
        Vincula una operación a una entidad vía su tabla de unión.

        entity: 'collection' | 'document' | 'image' | 'htr' | 'model'
        """
        if entity not in _ENTITY_JUNCTION:
            raise ValueError(
                f"Entidad desconocida: '{entity}'. "
                f"Opciones: {list(_ENTITY_JUNCTION.keys())}"
            )
        junction_table, fk_col = _ENTITY_JUNCTION[entity]
        cur = conn.cursor()
        cur.execute(
            f"INSERT INTO {junction_table} (operation_id, {fk_col}) "
            f"VALUES (%(op_id)s, %(entity_id)s) ON CONFLICT DO NOTHING",
            {"op_id": operation_id, "entity_id": entity_id},
        )

    @staticmethod
    def record_and_link(
        conn,
        operation_type: str,
        entity: str,
        entity_id: int,
        collaborator_id: Optional[int] = None,
        slurm_job_id: Optional[str] = None,
        transkribus_job_id: Optional[str] = None,
        status: str = "completed",
    ) -> int:
        """
        Conveniencia: inserta la operación y la vincula a la entidad.
        Devuelve el operation_id.

        Uso típico:
            op_id = Operations.record_and_link(
                conn,
                operation_type="image_registered",
                entity="image",
                entity_id=image_id,
            )
        """
        op_id = Operations.record(
            conn,
            operation_type=operation_type,
            collaborator_id=collaborator_id,
            slurm_job_id=slurm_job_id,
            transkribus_job_id=transkribus_job_id,
            status=status,
        )
        Operations.link(conn, op_id, entity, entity_id)
        return op_id

    @staticmethod
    def update_status(conn, operation_id: int, status: str) -> None:
        """
        Actualiza el status de una operación asíncrona.
        Útil para jobs de Slurm y jobs de Transkribus.

        status: 'pending' | 'running' | 'completed' | 'failed'
        """
        cur = conn.cursor()
        cur.execute(
            "UPDATE public.operations SET status = %(status)s "
            "WHERE operation_id = %(op_id)s",
            {"status": status, "op_id": operation_id},
        )

    @staticmethod
    def get_last(
        conn,
        operation_type: str,
        entity: str,
        entity_id: int,
        status: Optional[str] = None,
    ) -> Optional[dict]:
        """
        Devuelve la última operación de un tipo sobre una entidad (o None).
        Si status no es None, filtra por ese status.
        """
        if entity not in _ENTITY_JUNCTION:
            raise ValueError(f"Entidad desconocida: '{entity}'")

        junction_table, fk_col = _ENTITY_JUNCTION[entity]
        status_clause = "AND o.status = %(status)s" if status else ""

        cur = conn.cursor()
        cur.execute(
            f"""
            SELECT o.*
            FROM public.operations o
            JOIN {junction_table} j ON o.operation_id = j.operation_id
            JOIN public.operation_types ot ON o.operation_type_id = ot.operation_type_id
            WHERE j.{fk_col} = %(entity_id)s
              AND ot.operation_type = %(operation_type)s
              {status_clause}
            ORDER BY o.logged_at DESC
            LIMIT 1
            """,
            {
                "entity_id":      entity_id,
                "operation_type": operation_type,
                "status":         status,
            },
        )
        row = cur.fetchone()
        return dict(row) if row else None

    @staticmethod
    def has_completed(
        conn,
        operation_type: str,
        entity: str,
        entity_id: int,
    ) -> bool:
        """
        Devuelve True si la entidad ya tiene una operación de ese tipo
        con status='completed'.
        """
        return Operations.get_last(
            conn, operation_type, entity, entity_id, status="completed"
        ) is not None

    @staticmethod
    def get_transkribus_job_id(
        conn,
        operation_type: str,
        entity: str,
        entity_id: int,
    ) -> Optional[str]:
        """
        Devuelve el transkribus_job_id de la última operación asíncrona
        de un tipo sobre una entidad.
        """
        op = Operations.get_last(conn, operation_type, entity, entity_id)
        return op["transkribus_job_id"] if op else None


# ──────────────────────────────────────────────────────────────
# DESCRIPTIVE ANALYSIS — métricas de calidad por documento/HTR
# ──────────────────────────────────────────────────────────────

class DescriptiveAnalysis:
    """Registro de métricas de calidad en public.descriptive_analysis."""

    @staticmethod
    def record(
        conn,
        document_id: int,
        analysis_type: str,
        htr_id: Optional[int] = None,
        model_id: Optional[int] = None,
        cer: Optional[float] = None,
        wer: Optional[float] = None,
        bleu: Optional[float] = None,
        chrf_pp: Optional[float] = None,
        abbrev_accuracy: Optional[float] = None,
        entity_preservation: Optional[float] = None,
        rules_compliance_score: Optional[float] = None,
        n_errors: Optional[int] = None,
        n_patterns: Optional[int] = None,
        n_corrections: Optional[int] = None,
    ) -> int:
        """
        Crea un registro de análisis descriptivo. Devuelve el descriptive_analysis_id.

        analysis_type debe coincidir con un valor en public.analysis_types:
          'htr_baseline' | 'post_historical_clean' | 'post_clean_modern' |
          'ground_truth_comparison' | 'human_review'

        Uso:
            da_id = DescriptiveAnalysis.record(
                conn,
                document_id=42,
                analysis_type="post_historical_clean",
                htr_id=100,
                cer=0.035,
                wer=0.08,
                abbrev_accuracy=0.96,
                entity_preservation=0.99,
            )
        """
        cur = conn.cursor()
        cur.execute(
            "SELECT analysis_type_id FROM public.analysis_types "
            "WHERE analysis_type = %(analysis_type)s",
            {"analysis_type": analysis_type},
        )
        row = cur.fetchone()
        if row is None:
            raise ValueError(
                f"Tipo de análisis desconocido: '{analysis_type}'. "
                f"Opciones en public.analysis_types."
            )
        analysis_type_id = row["analysis_type_id"]

        cur.execute(
            """
            INSERT INTO public.descriptive_analysis (
                document_id, htr_id, analysis_type_id, model_id,
                cer, wer, bleu, chrf_pp,
                abbrev_accuracy, entity_preservation, rules_compliance_score,
                n_errors, n_patterns, n_corrections
            ) VALUES (
                %(document_id)s, %(htr_id)s, %(analysis_type_id)s, %(model_id)s,
                %(cer)s, %(wer)s, %(bleu)s, %(chrf_pp)s,
                %(abbrev_accuracy)s, %(entity_preservation)s, %(rules_compliance_score)s,
                %(n_errors)s, %(n_patterns)s, %(n_corrections)s
            )
            RETURNING descriptive_analysis_id
            """,
            {
                "document_id":            document_id,
                "htr_id":                 htr_id,
                "analysis_type_id":       analysis_type_id,
                "model_id":               model_id,
                "cer":                    cer,
                "wer":                    wer,
                "bleu":                   bleu,
                "chrf_pp":               chrf_pp,
                "abbrev_accuracy":        abbrev_accuracy,
                "entity_preservation":    entity_preservation,
                "rules_compliance_score": rules_compliance_score,
                "n_errors":               n_errors,
                "n_patterns":             n_patterns,
                "n_corrections":          n_corrections,
            },
        )
        return cur.fetchone()["descriptive_analysis_id"]

    @staticmethod
    def get_latest(
        conn,
        document_id: int,
        analysis_type: Optional[str] = None,
    ) -> Optional[dict]:
        """
        Devuelve el análisis más reciente de un documento.
        Si analysis_type se especifica, filtra por ese tipo.
        """
        type_clause = (
            "AND at.analysis_type = %(analysis_type)s"
            if analysis_type else ""
        )
        cur = conn.cursor()
        cur.execute(
            f"""
            SELECT da.*, at.analysis_type
            FROM public.descriptive_analysis da
            JOIN public.analysis_types at ON da.analysis_type_id = at.analysis_type_id
            WHERE da.document_id = %(document_id)s
            {type_clause}
            ORDER BY da.analyzed_at DESC
            LIMIT 1
            """,
            {"document_id": document_id, "analysis_type": analysis_type},
        )
        row = cur.fetchone()
        return dict(row) if row else None


# ──────────────────────────────────────────────────────────────
# PIPELINE STATUS — queries de estado del pipeline
# ──────────────────────────────────────────────────────────────

class PipelineStatus:
    """Consultas de estado del pipeline por colección o entidad."""

    @staticmethod
    def get_documents_pending(conn, operation_type: str) -> list[dict]:
        """
        Devuelve documentos que aún no tienen completada una operación de un tipo dado.
        Útil para construir batch files para jobs de Slurm.
        """
        cur = conn.cursor()
        cur.execute(
            """
            SELECT d.document_id, d.document_filename, d.document_path,
                   c.collection_name
            FROM public.documents d
            JOIN public.collections c ON d.collection_id = c.collection_id
            WHERE NOT EXISTS (
                SELECT 1
                FROM public.documents_operations dop
                JOIN public.operations o ON dop.operation_id = o.operation_id
                JOIN public.operation_types ot ON o.operation_type_id = ot.operation_type_id
                WHERE dop.document_id = d.document_id
                  AND ot.operation_type = %(operation_type)s
                  AND o.status = 'completed'
            )
            ORDER BY c.collection_name, d.document_filename
            """,
            {"operation_type": operation_type},
        )
        return [dict(r) for r in cur.fetchall()]

    @staticmethod
    def get_images_pending(conn, operation_type: str) -> list[dict]:
        """
        Devuelve imágenes que no tienen completada una operación de un tipo dado.
        """
        cur = conn.cursor()
        cur.execute(
            """
            SELECT i.image_id, i.image_filename, i.image_path,
                   i.document_id, it.image_type
            FROM public.images i
            JOIN public.image_types it ON i.image_type_id = it.image_type_id
            WHERE NOT EXISTS (
                SELECT 1
                FROM public.images_operations io
                JOIN public.operations o ON io.operation_id = o.operation_id
                JOIN public.operation_types ot ON o.operation_type_id = ot.operation_type_id
                WHERE io.image_id = i.image_id
                  AND ot.operation_type = %(operation_type)s
                  AND o.status = 'completed'
            )
            ORDER BY i.document_id, i.page_number
            """,
            {"operation_type": operation_type},
        )
        return [dict(r) for r in cur.fetchall()]

    @staticmethod
    def get_htr_pending(conn, operation_type: str) -> list[dict]:
        """
        Devuelve HTR files que no tienen completada una operación de un tipo dado.
        """
        cur = conn.cursor()
        cur.execute(
            """
            SELECT h.htr_id, h.htr_path, h.image_id
            FROM public.htr h
            WHERE NOT EXISTS (
                SELECT 1
                FROM public.htr_operations ho
                JOIN public.operations o ON ho.operation_id = o.operation_id
                JOIN public.operation_types ot ON o.operation_type_id = ot.operation_type_id
                WHERE ho.htr_id = h.htr_id
                  AND ot.operation_type = %(operation_type)s
                  AND o.status = 'completed'
            )
            ORDER BY h.htr_id
            """,
            {"operation_type": operation_type},
        )
        return [dict(r) for r in cur.fetchall()]


# ──────────────────────────────────────────────────────────────
# Singletons para importación directa
# ──────────────────────────────────────────────────────────────
operations        = Operations()
analysis          = DescriptiveAnalysis()
operation_types   = OperationTypes()
pipeline_status   = PipelineStatus()
