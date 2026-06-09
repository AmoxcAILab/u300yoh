"""
database/crud_operations.py
───────────────────────────
Operaciones CRUD para las entidades principales del schema public.
Cada create() registra la operación correspondiente en public.operations.

PKs son UUID en todas las tablas (gen_random_uuid()).
Los IDs se manejan como strings en Python; psycopg2 los convierte automáticamente.

Uso típico:
  from database.crud_operations import Collections, Documents, Notes
  from database.migration.db import get_conn

  with get_conn() as conn:
      collection_id = Collections.create(
          conn,
          collection_name="Marina",
          collection_type="AGN",
          archival_institution="Archivo General de la Nación",
      )
"""

from __future__ import annotations

from typing import Optional

from psycopg2 import sql

from database.migration.db import get_conn, Operations, resolve_collaborator_id


# Columnas archivísticas definidas en el schema actual.
# Campos de .metadata que no estén aquí se añaden vía ALTER TABLE ADD COLUMN.
_DOCUMENT_SCHEMA_COLUMNS: frozenset[str] = frozenset({
    "document_archive",
    "document_Fondo",
    "document_Volumen",
    "document_Caja",
    "document_Tomo",
    "document_Documento",
    "document_Legajo",
    "document_Expediente",
    "document_Titulo",
    "document_Signatura",
    "document_Productores",
    "document_Indices_de_Descripcion",
    "document_Fecha_creacion",
    "document_Año_creacion",
    "document_Lugar_creacion",
    "document_Soporte",
    "document_Descripcion",
    "document_Rango_fojas",
    "document_Num_pags",
    "document_Num_pags_escritas",
})


# ──────────────────────────────────────────────────────────────
# COLLECTIONS
# ──────────────────────────────────────────────────────────────

class Collections:
    """CRUD para public.collections."""

    @staticmethod
    def create(
        conn,
        collection_name: str,
        collection_type: str = "AGN",
        collection_status: str = "new",
        collection_path: Optional[str] = None,
        collection_url: Optional[str] = None,
        archival_institution: Optional[str] = None,
        collaborator_id: Optional[str] = None,
    ) -> str:
        """
        Inserta una colección y registra collection_registered.
        Devuelve el collection_id (UUID string).
        """
        cur = conn.cursor()
        collaborator_id = resolve_collaborator_id(conn, collaborator_id)

        cur.execute(
            "SELECT collection_type_id FROM public.collection_types "
            "WHERE collection_type = %(t)s",
            {"t": collection_type},
        )
        row = cur.fetchone()
        if row is None:
            raise ValueError(f"collection_type desconocido: '{collection_type}'")
        collection_type_id = row["collection_type_id"]

        cur.execute(
            "SELECT collection_status_id FROM public.collection_statuses "
            "WHERE collection_status = %(s)s",
            {"s": collection_status},
        )
        row = cur.fetchone()
        collection_status_id = row["collection_status_id"] if row else None

        archival_institution_id = None
        if archival_institution:
            cur.execute(
                "SELECT archival_institution_id FROM public.archival_institutions "
                "WHERE archival_institution_name = %(n)s",
                {"n": archival_institution},
            )
            row = cur.fetchone()
            archival_institution_id = row["archival_institution_id"] if row else None

        cur.execute(
            """
            INSERT INTO public.collections (
                collection_name, collection_path, collection_type_id,
                collection_status_id, collection_url, archival_institution_id
            ) VALUES (
                %(name)s, %(path)s, %(type_id)s,
                %(status_id)s, %(url)s, %(inst_id)s
            )
            RETURNING collection_id
            """,
            {
                "name":      collection_name,
                "path":      collection_path,
                "type_id":   collection_type_id,
                "status_id": collection_status_id,
                "url":       collection_url,
                "inst_id":   archival_institution_id,
            },
        )
        collection_id = cur.fetchone()["collection_id"]

        Operations.record_and_link(
            conn,
            operation_type="collection_registered",
            entity="collection",
            entity_id=collection_id,
            collaborator_id=collaborator_id,
        )
        return collection_id

    @staticmethod
    def get_by_id(conn, collection_id: str) -> Optional[dict]:
        cur = conn.cursor()
        cur.execute(
            "SELECT c.*, ct.collection_type, cs.collection_status, "
            "       ai.archival_institution_name "
            "FROM public.collections c "
            "LEFT JOIN public.collection_types ct USING (collection_type_id) "
            "LEFT JOIN public.collection_statuses cs USING (collection_status_id) "
            "LEFT JOIN public.archival_institutions ai USING (archival_institution_id) "
            "WHERE c.collection_id = %(id)s",
            {"id": collection_id},
        )
        row = cur.fetchone()
        return dict(row) if row else None

    @staticmethod
    def list_all(conn) -> list[dict]:
        cur = conn.cursor()
        cur.execute(
            "SELECT c.*, ct.collection_type, cs.collection_status "
            "FROM public.collections c "
            "LEFT JOIN public.collection_types ct USING (collection_type_id) "
            "LEFT JOIN public.collection_statuses cs USING (collection_status_id) "
            "ORDER BY c.collection_name"
        )
        return [dict(r) for r in cur.fetchall()]

    @staticmethod
    def update_status(conn, collection_id: str, status: str) -> None:
        cur = conn.cursor()
        cur.execute(
            "UPDATE public.collections SET collection_status_id = "
            "(SELECT collection_status_id FROM public.collection_statuses "
            " WHERE collection_status = %(status)s) "
            "WHERE collection_id = %(id)s",
            {"status": status, "id": collection_id},
        )


# ──────────────────────────────────────────────────────────────
# DOCUMENTS
# ──────────────────────────────────────────────────────────────

class Documents:
    """CRUD para public.documents."""

    @staticmethod
    def _ensure_columns(conn, extra_fields: dict) -> None:
        """
        Para cada campo en extra_fields que no exista como columna en
        public.documents, añade la columna con ALTER TABLE ADD COLUMN IF NOT EXISTS.
        """
        cur = conn.cursor()
        cur.execute(
            "SELECT column_name FROM information_schema.columns "
            "WHERE table_schema = 'public' AND table_name = 'documents'"
        )
        existing = {row["column_name"] for row in cur.fetchall()}
        for field in extra_fields:
            if field not in existing:
                cur.execute(
                    sql.SQL(
                        "ALTER TABLE public.documents "
                        "ADD COLUMN IF NOT EXISTS {} TEXT"
                    ).format(sql.Identifier(field))
                )

    @staticmethod
    def create(
        conn,
        collection_id: str,
        document_name: str,
        document_status: str = "new",
        document_path: Optional[str] = None,
        document_url: Optional[str] = None,
        collaborator_id: Optional[str] = None,
        **archival_fields,
    ) -> str:
        """
        Inserta un documento con sus campos archivísticos y registra document_registered.
        Los campos en archival_fields que no existan como columna se añaden dinámicamente.
        Devuelve el document_id (UUID string).
        """
        cur = conn.cursor()
        collaborator_id = resolve_collaborator_id(conn, collaborator_id)

        cur.execute(
            "SELECT document_status_id FROM public.document_statuses "
            "WHERE document_status = %(s)s",
            {"s": document_status},
        )
        row = cur.fetchone()
        document_status_id = row["document_status_id"] if row else None

        # Filtrar campos vacíos y garantizar que existen las columnas dinámicas
        extra = {k: v for k, v in archival_fields.items() if v is not None and v != ""}
        Documents._ensure_columns(conn, extra)

        # Construir INSERT dinámico
        params: dict = {
            "collection_id":       collection_id,
            "document_name":       document_name,
            "document_status_id":  document_status_id,
            "document_path":       document_path,
            "document_url":        document_url,
        }
        params.update(extra)

        col_parts = [sql.Identifier(k) for k in params]
        ph_parts  = [sql.Placeholder(k) for k in params]

        query = sql.SQL(
            "INSERT INTO public.documents ({cols}) VALUES ({vals}) "
            "RETURNING document_id"
        ).format(
            cols=sql.SQL(", ").join(col_parts),
            vals=sql.SQL(", ").join(ph_parts),
        )
        cur.execute(query, params)
        document_id = cur.fetchone()["document_id"]

        Operations.record_and_link(
            conn,
            operation_type="document_registered",
            entity="document",
            entity_id=document_id,
            collaborator_id=collaborator_id,
        )
        return document_id

    @staticmethod
    def get_by_id(conn, document_id: str) -> Optional[dict]:
        cur = conn.cursor()
        cur.execute(
            "SELECT d.*, ds.document_status, c.collection_name "
            "FROM public.documents d "
            "LEFT JOIN public.document_statuses ds USING (document_status_id) "
            "LEFT JOIN public.collections c USING (collection_id) "
            "WHERE d.document_id = %(id)s",
            {"id": document_id},
        )
        row = cur.fetchone()
        return dict(row) if row else None

    @staticmethod
    def get_by_collection(conn, collection_id: str) -> list[dict]:
        cur = conn.cursor()
        cur.execute(
            "SELECT d.*, ds.document_status "
            "FROM public.documents d "
            "LEFT JOIN public.document_statuses ds USING (document_status_id) "
            "WHERE d.collection_id = %(id)s "
            "ORDER BY d.document_name",
            {"id": collection_id},
        )
        return [dict(r) for r in cur.fetchall()]

    @staticmethod
    def update_status(conn, document_id: str, status: str) -> None:
        cur = conn.cursor()
        cur.execute(
            "UPDATE public.documents SET document_status_id = "
            "(SELECT document_status_id FROM public.document_statuses "
            " WHERE document_status = %(status)s) "
            "WHERE document_id = %(id)s",
            {"status": status, "id": document_id},
        )


# ──────────────────────────────────────────────────────────────
# NOTES
# ──────────────────────────────────────────────────────────────

class Notes:
    """CRUD para public.notes y sus tablas junction."""

    @staticmethod
    def create(conn, note_text: str) -> str:
        """Inserta una nota y devuelve su note_id (UUID string)."""
        cur = conn.cursor()
        cur.execute(
            "INSERT INTO public.notes (note) VALUES (%(note)s) RETURNING note_id",
            {"note": note_text},
        )
        return cur.fetchone()["note_id"]

    @staticmethod
    def link_to_document(conn, note_id: str, document_id: str) -> None:
        cur = conn.cursor()
        cur.execute(
            "INSERT INTO public.notes_documents (note_id, document_id) "
            "VALUES (%(nid)s, %(did)s) ON CONFLICT DO NOTHING",
            {"nid": note_id, "did": document_id},
        )

    @staticmethod
    def link_to_collection(conn, note_id: str, collection_id: str) -> None:
        cur = conn.cursor()
        cur.execute(
            "INSERT INTO public.notes_collections (note_id, collection_id) "
            "VALUES (%(nid)s, %(cid)s) ON CONFLICT DO NOTHING",
            {"nid": note_id, "cid": collection_id},
        )

    @staticmethod
    def link_to_operation(conn, note_id: str, operation_id: str) -> None:
        cur = conn.cursor()
        cur.execute(
            "INSERT INTO public.notes_operations (note_id, operation_id) "
            "VALUES (%(nid)s, %(oid)s) ON CONFLICT DO NOTHING",
            {"nid": note_id, "oid": operation_id},
        )


# ──────────────────────────────────────────────────────────────
# IMAGES
# ──────────────────────────────────────────────────────────────

class Images:
    """CRUD para public.images."""

    @staticmethod
    def create(
        conn,
        document_id: str,
        image_filename: str,
        image_path: Optional[str] = None,
        image_url: Optional[str] = None,
        image_type: str = "original",
        parent_image_id: Optional[str] = None,
        page_number: Optional[int] = None,
        collaborator_id: Optional[str] = None,
    ) -> str:
        cur = conn.cursor()
        collaborator_id = resolve_collaborator_id(conn, collaborator_id)

        cur.execute(
            "SELECT image_type_id FROM public.image_types WHERE image_type = %(t)s",
            {"t": image_type},
        )
        row = cur.fetchone()
        image_type_id = row["image_type_id"] if row else None

        cur.execute(
            """
            INSERT INTO public.images (
                document_id, parent_image_id, image_filename,
                image_url, image_path, image_type_id, page_number
            ) VALUES (
                %(doc_id)s, %(parent_id)s, %(filename)s,
                %(url)s, %(path)s, %(type_id)s, %(page)s
            )
            RETURNING image_id
            """,
            {
                "doc_id":    document_id,
                "parent_id": parent_image_id,
                "filename":  image_filename,
                "url":       image_url,
                "path":      image_path,
                "type_id":   image_type_id,
                "page":      page_number,
            },
        )
        image_id = cur.fetchone()["image_id"]

        Operations.record_and_link(
            conn,
            operation_type="image_registered",
            entity="image",
            entity_id=image_id,
            collaborator_id=collaborator_id,
        )
        return image_id

    @staticmethod
    def get_by_id(conn, image_id: str) -> Optional[dict]:
        cur = conn.cursor()
        cur.execute(
            "SELECT i.*, it.image_type FROM public.images i "
            "LEFT JOIN public.image_types it USING (image_type_id) "
            "WHERE i.image_id = %(id)s",
            {"id": image_id},
        )
        row = cur.fetchone()
        return dict(row) if row else None

    @staticmethod
    def get_by_document(conn, document_id: str, image_type: Optional[str] = None) -> list[dict]:
        type_clause = "AND it.image_type = %(image_type)s" if image_type else ""
        cur = conn.cursor()
        cur.execute(
            f"""
            SELECT i.*, it.image_type
            FROM public.images i
            LEFT JOIN public.image_types it USING (image_type_id)
            WHERE i.document_id = %(doc_id)s
            {type_clause}
            ORDER BY i.page_number, i.image_filename
            """,
            {"doc_id": document_id, "image_type": image_type},
        )
        return [dict(r) for r in cur.fetchall()]


# ──────────────────────────────────────────────────────────────
# HTR
# ──────────────────────────────────────────────────────────────

class HTR:
    """CRUD para public.htr."""

    @staticmethod
    def create(
        conn,
        image_id: str,
        htr_path: str,
        htr_filename: Optional[str] = None,
        layout_id: Optional[str] = None,
        transkribus_model_id: Optional[str] = None,
        transkribus_job_id: Optional[str] = None,
        collaborator_id: Optional[str] = None,
    ) -> str:
        cur = conn.cursor()
        collaborator_id = resolve_collaborator_id(conn, collaborator_id)
        cur.execute(
            """
            INSERT INTO public.htr (
                image_id, layout_id, htr_filename, htr_path, transkribus_model_id
            ) VALUES (
                %(image_id)s, %(layout_id)s, %(filename)s, %(path)s, %(model_id)s
            )
            RETURNING htr_id
            """,
            {
                "image_id":  image_id,
                "layout_id": layout_id,
                "filename":  htr_filename,
                "path":      htr_path,
                "model_id":  transkribus_model_id,
            },
        )
        htr_id = cur.fetchone()["htr_id"]
        Operations.record_and_link(
            conn,
            operation_type="htr_available",
            entity="htr",
            entity_id=htr_id,
            collaborator_id=collaborator_id,
            transkribus_job_id=transkribus_job_id,
        )
        return htr_id

    @staticmethod
    def get_by_id(conn, htr_id: str) -> Optional[dict]:
        cur = conn.cursor()
        cur.execute("SELECT * FROM public.htr WHERE htr_id = %(id)s", {"id": htr_id})
        row = cur.fetchone()
        return dict(row) if row else None


# ──────────────────────────────────────────────────────────────
# GROUND TRUTH
# ──────────────────────────────────────────────────────────────

class GroundTruth:
    """CRUD para public.ground_truth."""

    @staticmethod
    def create(
        conn,
        htr_id: str,
        ground_truth_path: str,
        ground_truth_filename: Optional[str] = None,
        collaborator_id: Optional[str] = None,
    ) -> str:
        cur = conn.cursor()
        collaborator_id = resolve_collaborator_id(conn, collaborator_id)
        cur.execute(
            """
            INSERT INTO public.ground_truth (htr_id, ground_truth_filename, ground_truth_path)
            VALUES (%(htr_id)s, %(filename)s, %(path)s)
            RETURNING ground_truth_id
            """,
            {"htr_id": htr_id, "filename": ground_truth_filename, "path": ground_truth_path},
        )
        ground_truth_id = cur.fetchone()["ground_truth_id"]
        Operations.record_and_link(
            conn,
            operation_type="ground_truth_registered",
            entity="htr",
            entity_id=htr_id,
            collaborator_id=collaborator_id,
        )
        return ground_truth_id

    @staticmethod
    def get_by_htr(conn, htr_id: str) -> Optional[dict]:
        cur = conn.cursor()
        cur.execute("SELECT * FROM public.ground_truth WHERE htr_id = %(id)s LIMIT 1", {"id": htr_id})
        row = cur.fetchone()
        return dict(row) if row else None


# ──────────────────────────────────────────────────────────────
# MODELS
# ──────────────────────────────────────────────────────────────

class Models:
    """CRUD para public.models."""

    @staticmethod
    def create(
        conn,
        model_name: str,
        model_url: Optional[str] = None,
        model_filename: Optional[str] = None,
        model_version: Optional[str] = None,
        collaborator_id: Optional[str] = None,
    ) -> str:
        cur = conn.cursor()
        collaborator_id = resolve_collaborator_id(conn, collaborator_id)
        cur.execute(
            """
            INSERT INTO public.models (model_name, model_url, model_filename, model_version)
            VALUES (%(name)s, %(url)s, %(filename)s, %(version)s)
            RETURNING model_id
            """,
            {"name": model_name, "url": model_url, "filename": model_filename, "version": model_version},
        )
        model_id = cur.fetchone()["model_id"]
        Operations.record_and_link(
            conn,
            operation_type="model_registered",
            entity="model",
            entity_id=model_id,
            collaborator_id=collaborator_id,
        )
        return model_id

    @staticmethod
    def get_by_name(conn, model_name: str) -> Optional[dict]:
        cur = conn.cursor()
        cur.execute(
            "SELECT * FROM public.models WHERE model_name = %(name)s ORDER BY model_id DESC LIMIT 1",
            {"name": model_name},
        )
        row = cur.fetchone()
        return dict(row) if row else None

    @staticmethod
    def list_all(conn) -> list[dict]:
        cur = conn.cursor()
        cur.execute("SELECT * FROM public.models ORDER BY model_name")
        return [dict(r) for r in cur.fetchall()]
