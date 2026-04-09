"""
pipeline/db.py
──────────────
Módulo de conexión a BD local (PostgreSQL + pgvector).
Lee las variables de entorno exportadas por el flake de Nix.
Usado por todos los pasos del pipeline para registrar
observabilidad en el schema `pipeline`.

Variables de entorno esperadas (setteadas por el flake):
  HTR_DB_URL   postgresql://user@/htr_pipeline?host=/path/run&port=5433
  HTR_PGHOST   directorio del socket Unix
  HTR_PGPORT   puerto (default 5433)
  HTR_PGDB     nombre de la base de datos
  HTR_PGUSER   usuario

Uso típico:
  from pipeline.db import get_conn, pipeline_runs, trace

  with get_conn() as conn:
      run_id = pipeline_runs.create(conn, batch_name="batch_001")
      trace.upsert(conn, run_id=run_id, doc_id=42, status="in_progress")
"""

import os
import uuid
import json
from contextlib import contextmanager
from datetime import datetime, timezone
from typing import Optional

import psycopg2
import psycopg2.extras

# Registrar el adaptador de UUID para que psycopg2 lo maneje nativamente
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
            cur = conn.cursor()
            cur.execute(...)
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
# pipeline.pipeline_runs
# ──────────────────────────────────────────────────────────────

class PipelineRuns:
    """Operaciones sobre pipeline.pipeline_runs."""

    @staticmethod
    def create(
        conn,
        batch_name: str,
        total_docs: int = 0,
        parent_run_id: Optional[uuid.UUID] = None,
        is_reentry: bool = False,
        reentry_triggered_by_kb3_count: Optional[int] = None,
        slurm_job_id: Optional[str] = None,
        notes: Optional[str] = None,
    ) -> uuid.UUID:
        """Crea un nuevo pipeline_run y devuelve su UUID."""
        run_id = uuid.uuid4()
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO pipeline.pipeline_runs (
                id, parent_run_id, is_reentry,
                reentry_triggered_by_kb3_count,
                batch_name, total_docs, status,
                slurm_job_id, launched_by, notes
            ) VALUES (
                %(id)s, %(parent_run_id)s, %(is_reentry)s,
                %(reentry_triggered_by_kb3_count)s,
                %(batch_name)s, %(total_docs)s, 'running',
                %(slurm_job_id)s, %(launched_by)s, %(notes)s
            )
            """,
            {
                "id": run_id,
                "parent_run_id": parent_run_id,
                "is_reentry": is_reentry,
                "reentry_triggered_by_kb3_count": reentry_triggered_by_kb3_count,
                "batch_name": batch_name,
                "total_docs": total_docs,
                "slurm_job_id": slurm_job_id,
                "launched_by": os.environ.get("USER"),
                "notes": notes,
            },
        )
        return run_id

    @staticmethod
    def complete(
        conn,
        run_id: uuid.UUID,
        n_clean: int = 0,
        n_provisional: int = 0,
        n_blocked: int = 0,
        n_rejected: int = 0,
        status: str = "completed",
    ) -> None:
        cur = conn.cursor()
        cur.execute(
            """
            UPDATE pipeline.pipeline_runs SET
                status       = %(status)s,
                completed_at = NOW(),
                n_clean      = %(n_clean)s,
                n_provisional= %(n_provisional)s,
                n_blocked    = %(n_blocked)s,
                n_rejected   = %(n_rejected)s
            WHERE id = %(id)s
            """,
            {
                "id": run_id,
                "status": status,
                "n_clean": n_clean,
                "n_provisional": n_provisional,
                "n_blocked": n_blocked,
                "n_rejected": n_rejected,
            },
        )

    @staticmethod
    def fail(conn, run_id: uuid.UUID, notes: Optional[str] = None) -> None:
        cur = conn.cursor()
        cur.execute(
            """
            UPDATE pipeline.pipeline_runs SET
                status = 'failed', completed_at = NOW(),
                notes  = COALESCE(%(notes)s, notes)
            WHERE id = %(id)s
            """,
            {"id": run_id, "notes": notes},
        )


# ──────────────────────────────────────────────────────────────
# pipeline.pipeline_document_trace
# ──────────────────────────────────────────────────────────────

class DocumentTrace:
    """Operaciones sobre pipeline.pipeline_document_trace."""

    @staticmethod
    def init(
        conn,
        run_id: uuid.UUID,
        doc_id: int,
        parent_run_id: Optional[uuid.UUID] = None,
        reentry_count: int = 0,
    ) -> uuid.UUID:
        """Crea el registro inicial para un documento en una corrida."""
        trace_id = uuid.uuid4()
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO pipeline.pipeline_document_trace (
                id, run_id, doc_id, parent_run_id,
                reentry_count, status, paso0_at
            ) VALUES (
                %(id)s, %(run_id)s, %(doc_id)s, %(parent_run_id)s,
                %(reentry_count)s, 'in_progress', NOW()
            )
            ON CONFLICT (run_id, doc_id) DO NOTHING
            """,
            {
                "id": trace_id,
                "run_id": run_id,
                "doc_id": doc_id,
                "parent_run_id": parent_run_id,
                "reentry_count": reentry_count,
            },
        )
        return trace_id

    @staticmethod
    def update(conn, run_id: uuid.UUID, doc_id: int, **fields) -> None:
        """
        Actualiza campos arbitrarios del trace.
        Todos los campos de pipeline_document_trace son válidos como kwargs.

        Uso:
            trace.update(conn, run_id, doc_id,
                         handwriting_type="Procesal",
                         cer_baseline=8.5,
                         pc1_at="NOW()")
        """
        if not fields:
            return
        set_clauses = ", ".join(
            f"{k} = %({k})s" for k in fields
        )
        fields.update({"run_id": run_id, "doc_id": doc_id,
                       "updated_at_val": datetime.now(timezone.utc)})
        cur = conn.cursor()
        cur.execute(
            f"""
            UPDATE pipeline.pipeline_document_trace
            SET {set_clauses}, updated_at = %(updated_at_val)s
            WHERE run_id = %(run_id)s AND doc_id = %(doc_id)s
            """,
            fields,
        )

    @staticmethod
    def set_status(
        conn,
        run_id: uuid.UUID,
        doc_id: int,
        status: str,
        pc_timestamp_field: Optional[str] = None,
    ) -> None:
        """
        Actualiza el status y opcionalmente el timestamp de un PC.

        Uso:
            trace.set_status(conn, run_id, 42, 'blocked_entities',
                             pc_timestamp_field='pc3_at')
        """
        extra = f", {pc_timestamp_field} = NOW()" if pc_timestamp_field else ""
        cur = conn.cursor()
        cur.execute(
            f"""
            UPDATE pipeline.pipeline_document_trace
            SET status = %(status)s, updated_at = NOW() {extra}
            WHERE run_id = %(run_id)s AND doc_id = %(doc_id)s
            """,
            {"run_id": run_id, "doc_id": doc_id, "status": status},
        )

    @staticmethod
    def get(conn, run_id: uuid.UUID, doc_id: int) -> Optional[dict]:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT * FROM pipeline.pipeline_document_trace
            WHERE run_id = %(run_id)s AND doc_id = %(doc_id)s
            """,
            {"run_id": run_id, "doc_id": doc_id},
        )
        row = cur.fetchone()
        return dict(row) if row else None


# ──────────────────────────────────────────────────────────────
# pipeline.pipeline_review_queue
# ──────────────────────────────────────────────────────────────

class ReviewQueue:
    """Operaciones sobre pipeline.pipeline_review_queue."""

    @staticmethod
    def enqueue(
        conn,
        run_id: uuid.UUID,
        doc_id: int,
        trace_id: uuid.UUID,
        reason: str,
        n_entities_pending: int = 0,
    ) -> None:
        """
        Agrega un documento a la cola de revisión.
        Prioridad alta si reason = 'blocked_entities'.
        """
        priority = "high" if reason == "blocked_entities" else "low"
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO pipeline.pipeline_review_queue (
                run_id, doc_id, trace_id,
                priority, reason, n_entities_pending
            ) VALUES (
                %(run_id)s, %(doc_id)s, %(trace_id)s,
                %(priority)s, %(reason)s, %(n_entities_pending)s
            )
            ON CONFLICT (run_id, doc_id) DO UPDATE SET
                priority           = EXCLUDED.priority,
                n_entities_pending = EXCLUDED.n_entities_pending,
                updated_at         = NOW()
            """,
            {
                "run_id": run_id,
                "doc_id": doc_id,
                "trace_id": trace_id,
                "priority": priority,
                "reason": reason,
                "n_entities_pending": n_entities_pending,
            },
        )


# ──────────────────────────────────────────────────────────────
# pipeline.pipeline_run_metrics
# ──────────────────────────────────────────────────────────────

class RunMetrics:
    """Registro granular de métricas por paso."""

    @staticmethod
    def record(
        conn,
        run_id: uuid.UUID,
        step_name: str,
        metric_name: str,
        metric_value: Optional[float] = None,
        metric_text: Optional[str] = None,
        doc_id: Optional[int] = None,
    ) -> None:
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO pipeline.pipeline_run_metrics (
                run_id, doc_id, step_name,
                metric_name, metric_value, metric_text
            ) VALUES (
                %(run_id)s, %(doc_id)s, %(step_name)s,
                %(metric_name)s, %(metric_value)s, %(metric_text)s
            )
            """,
            {
                "run_id": run_id,
                "doc_id": doc_id,
                "step_name": step_name,
                "metric_name": metric_name,
                "metric_value": metric_value,
                "metric_text": metric_text,
            },
        )

    @staticmethod
    def record_batch(
        conn,
        run_id: uuid.UUID,
        step_name: str,
        metrics: dict,
        doc_id: Optional[int] = None,
    ) -> None:
        """
        Registra múltiples métricas de un paso de una vez.

        Uso:
            metrics.record_batch(conn, run_id, "pc2",
                {"cer_delta": -0.3, "abbreviation_expansion_rate": 97.2},
                doc_id=42)
        """
        for name, value in metrics.items():
            if isinstance(value, (int, float)):
                RunMetrics.record(conn, run_id, step_name, name,
                                  metric_value=float(value), doc_id=doc_id)
            else:
                RunMetrics.record(conn, run_id, step_name, name,
                                  metric_text=str(value), doc_id=doc_id)


# ──────────────────────────────────────────────────────────────
# pipeline_config
# ──────────────────────────────────────────────────────────────

class PipelineConfig:
    """Lee y escribe parámetros de pipeline.pipeline_config."""

    _cache: dict = {}

    @classmethod
    def get(cls, conn, key: str, default=None):
        cur = conn.cursor()
        cur.execute(
            "SELECT value FROM pipeline.pipeline_config WHERE key = %(key)s",
            {"key": key},
        )
        row = cur.fetchone()
        if row is None:
            return default
        return row["value"]

    @classmethod
    def get_float(cls, conn, key: str, default: float = 0.0) -> float:
        return float(cls.get(conn, key, default))

    @classmethod
    def get_int(cls, conn, key: str, default: int = 0) -> int:
        return int(cls.get(conn, key, default))

    @classmethod
    def set(cls, conn, key: str, value: str, updated_by: Optional[str] = None) -> None:
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO pipeline.pipeline_config (key, value, updated_by)
            VALUES (%(key)s, %(value)s, %(updated_by)s)
            ON CONFLICT (key) DO UPDATE SET
                value      = EXCLUDED.value,
                updated_by = EXCLUDED.updated_by,
                updated_at = NOW()
            """,
            {
                "key": key,
                "value": str(value),
                "updated_by": updated_by or os.environ.get("USER"),
            },
        )


# ──────────────────────────────────────────────────────────────
# Re-entrada — consulta de candidatos y trigger
# ──────────────────────────────────────────────────────────────

class ReentryManager:
    """Gestión del ciclo de re-entrada desde PASO 6."""

    @staticmethod
    def should_trigger(conn) -> bool:
        """
        Devuelve True si KB-3 ha acumulado suficientes entidades
        verificadas nuevas desde la última re-entrada para disparar
        un nuevo ciclo (umbral en pipeline_config).
        """
        threshold = PipelineConfig.get_int(conn, "umbral_reentrada", 50)
        cur = conn.cursor()
        cur.execute(
            """
            SELECT COUNT(*) AS nuevas
            FROM rag.knowledge_base
            WHERE kb_type = 'entity'
              AND verified = TRUE
              AND added_at > COALESCE(
                  (SELECT MAX(started_at)
                   FROM pipeline.pipeline_runs
                   WHERE is_reentry = TRUE),
                  '1900-01-01'::timestamptz
              )
            """
        )
        row = cur.fetchone()
        nuevas = row["nuevas"] if row else 0
        return nuevas >= threshold

    @staticmethod
    def get_candidates(conn) -> list[dict]:
        """
        Devuelve documentos candidatos a re-entrada ordenados
        por n_unmatched DESC (los más probables de desbloquear primero).
        """
        cur = conn.cursor()
        cur.execute("SELECT * FROM pipeline.v_reentry_candidates")
        return [dict(r) for r in cur.fetchall()]

    @staticmethod
    def create_reentry_run(
        conn,
        parent_run_id: uuid.UUID,
        triggered_by_kb3_count: int,
        batch_name: Optional[str] = None,
    ) -> uuid.UUID:
        """Crea el pipeline_run de re-entrada."""
        name = batch_name or f"reentry_{datetime.now(timezone.utc).strftime('%Y%m%d_%H%M%S')}"
        return PipelineRuns.create(
            conn,
            batch_name=name,
            parent_run_id=parent_run_id,
            is_reentry=True,
            reentry_triggered_by_kb3_count=triggered_by_kb3_count,
            notes=f"Re-entrada automática desde run {parent_run_id}",
        )


# ──────────────────────────────────────────────────────────────
# Singletons para importación directa
# ──────────────────────────────────────────────────────────────
pipeline_runs = PipelineRuns()
trace         = DocumentTrace()
review_queue  = ReviewQueue()
metrics       = RunMetrics()
config        = PipelineConfig()
reentry       = ReentryManager()
