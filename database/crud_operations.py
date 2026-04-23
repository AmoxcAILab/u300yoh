"""
database/crud_operations.py
───────────────────────────
Operaciones CRUD para las entidades principales del schema public.
Cada create() registra la operación correspondiente en public.operations.

Uso típico:
  from database.crud_operations import Collections, Documents, Images, HTR
  from database.migration.db import get_conn

  with get_conn() as conn:
      collection_id = Collections.create(
          conn,
          collection_name="AGN_Flotas_Serie_1",
          collection_type="AGN",
          collection_path="/data/AGN_Flotas_Serie_1",
      )
"""

from __future__ import annotations

from typing import Optional

from database.migration.db import get_conn, Operations


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
        collection_path: Optional[str] = None,
        collection_url: Optional[str] = None,
        metadata_csv_path: Optional[str] = None,
        detail: Optional[str] = None,
        collaborator_id: Optional[int] = None,
    ) -> int:
        """
        Inserta una colección y registra la operación collection_registered.
        Devuelve el collection_id asignado.
        """
        cur = conn.cursor()

        # Resolver collection_type_id
        cur.execute(
            "SELECT collection_type_id FROM public.collection_types "
            "WHERE collection_type = %(t)s",
            {"t": collection_type},
        )
        row = cur.fetchone()
        collection_type_id = row["collection_type_id"] if row else None

        # Resolver collection_status_id inicial
        cur.execute(
            "SELECT collection_status_id FROM public.collection_statuses "
            "WHERE collection_status = 'active'",
        )
        row = cur.fetchone()
        collection_status_id = row["collection_status_id"] if row else None

        cur.execute(
            """
            INSERT INTO public.collections (
                collection_name, collection_path, collection_type_id,
                collection_status_id, collection_url,
                metadata_csv_path, collection_detail_1
            ) VALUES (
                %(name)s, %(path)s, %(type_id)s,
                %(status_id)s, %(url)s,
                %(csv_path)s, %(detail)s
            )
            RETURNING collection_id
            """,
            {
                "name":      collection_name,
                "path":      collection_path,
                "type_id":   collection_type_id,
                "status_id": collection_status_id,
                "url":       collection_url,
                "csv_path":  metadata_csv_path,
                "detail":    detail,
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
    def get_by_id(conn, collection_id: int) -> Optional[dict]:
        cur = conn.cursor()
        cur.execute(
            "SELECT c.*, ct.collection_type, cs.collection_status "
            "FROM public.collections c "
            "LEFT JOIN public.collection_types ct ON c.collection_type_id = ct.collection_type_id "
            "LEFT JOIN public.collection_statuses cs ON c.collection_status_id = cs.collection_status_id "
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
            "LEFT JOIN public.collection_types ct ON c.collection_type_id = ct.collection_type_id "
            "LEFT JOIN public.collection_statuses cs ON c.collection_status_id = cs.collection_status_id "
            "ORDER BY c.collection_id"
        )
        return [dict(r) for r in cur.fetchall()]

    @staticmethod
    def update_status(conn, collection_id: int, status: str) -> None:
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
    def create(
        conn,
        collection_id: int,
        document_filename: str,
        document_path: Optional[str] = None,
        document_url: Optional[str] = None,
        detail: Optional[str] = None,
        collaborator_id: Optional[int] = None,
    ) -> int:
        """
        Inserta un documento y registra la operación document_registered.
        Devuelve el document_id asignado.
        """
        cur = conn.cursor()

        # Estado inicial: new_untouched
        cur.execute(
            "SELECT document_status_id FROM public.document_statuses "
            "WHERE document_status = 'new_untouched'"
        )
        row = cur.fetchone()
        initial_status_id = row["document_status_id"] if row else None

        cur.execute(
            """
            INSERT INTO public.documents (
                collection_id, document_filename, document_path,
                document_status_id, document_url, document_detail_1
            ) VALUES (
                %(collection_id)s, %(filename)s, %(path)s,
                %(status_id)s, %(url)s, %(detail)s
            )
            RETURNING document_id
            """,
            {
                "collection_id": collection_id,
                "filename":      document_filename,
                "path":          document_path,
                "status_id":     initial_status_id,
                "url":           document_url,
                "detail":        detail,
            },
        )
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
    def get_by_id(conn, document_id: int) -> Optional[dict]:
        cur = conn.cursor()
        cur.execute(
            "SELECT d.*, ds.document_status, c.collection_name "
            "FROM public.documents d "
            "LEFT JOIN public.document_statuses ds ON d.document_status_id = ds.document_status_id "
            "LEFT JOIN public.collections c ON d.collection_id = c.collection_id "
            "WHERE d.document_id = %(id)s",
            {"id": document_id},
        )
        row = cur.fetchone()
        return dict(row) if row else None

    @staticmethod
    def get_by_collection(conn, collection_id: int) -> list[dict]:
        cur = conn.cursor()
        cur.execute(
            "SELECT d.*, ds.document_status "
            "FROM public.documents d "
            "LEFT JOIN public.document_statuses ds ON d.document_status_id = ds.document_status_id "
            "WHERE d.collection_id = %(id)s "
            "ORDER BY d.document_filename",
            {"id": collection_id},
        )
        return [dict(r) for r in cur.fetchall()]

    @staticmethod
    def update_status(conn, document_id: int, status: str) -> None:
        cur = conn.cursor()
        cur.execute(
            "UPDATE public.documents SET document_status_id = "
            "(SELECT document_status_id FROM public.document_statuses "
            " WHERE document_status = %(status)s) "
            "WHERE document_id = %(id)s",
            {"status": status, "id": document_id},
        )


# ──────────────────────────────────────────────────────────────
# IMAGES
# ──────────────────────────────────────────────────────────────

class Images:
    """CRUD para public.images."""

    @staticmethod
    def create(
        conn,
        document_id: int,
        image_filename: str,
        image_path: Optional[str] = None,
        image_url: Optional[str] = None,
        image_type: str = "original",
        parent_image_id: Optional[int] = None,
        page_number: Optional[int] = None,
        collaborator_id: Optional[int] = None,
    ) -> int:
        """
        Inserta una imagen y registra image_registered.
        image_type: 'original' | 'processed'
        parent_image_id: para imágenes procesadas, ID de la original.
        Devuelve el image_id asignado.
        """
        cur = conn.cursor()

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
    def get_by_id(conn, image_id: int) -> Optional[dict]:
        cur = conn.cursor()
        cur.execute(
            "SELECT i.*, it.image_type "
            "FROM public.images i "
            "LEFT JOIN public.image_types it ON i.image_type_id = it.image_type_id "
            "WHERE i.image_id = %(id)s",
            {"id": image_id},
        )
        row = cur.fetchone()
        return dict(row) if row else None

    @staticmethod
    def get_by_document(
        conn, document_id: int, image_type: Optional[str] = None
    ) -> list[dict]:
        type_clause = (
            "AND it.image_type = %(image_type)s" if image_type else ""
        )
        cur = conn.cursor()
        cur.execute(
            f"""
            SELECT i.*, it.image_type
            FROM public.images i
            LEFT JOIN public.image_types it ON i.image_type_id = it.image_type_id
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
        image_id: int,
        htr_path: str,
        htr_filename: Optional[str] = None,
        layout_id: Optional[int] = None,
        transkribus_model_id: Optional[str] = None,
        transkribus_job_id: Optional[str] = None,
        collaborator_id: Optional[int] = None,
    ) -> int:
        """
        Inserta un registro HTR y registra htr_available.
        Devuelve el htr_id asignado.
        """
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO public.htr (
                image_id, layout_id, htr_filename,
                htr_path, transkribus_model_id
            ) VALUES (
                %(image_id)s, %(layout_id)s, %(filename)s,
                %(path)s, %(model_id)s
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
    def get_by_id(conn, htr_id: int) -> Optional[dict]:
        cur = conn.cursor()
        cur.execute(
            "SELECT * FROM public.htr WHERE htr_id = %(id)s",
            {"id": htr_id},
        )
        row = cur.fetchone()
        return dict(row) if row else None

    @staticmethod
    def get_by_image(conn, image_id: int) -> Optional[dict]:
        cur = conn.cursor()
        cur.execute(
            "SELECT * FROM public.htr WHERE image_id = %(id)s LIMIT 1",
            {"id": image_id},
        )
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
        htr_id: int,
        ground_truth_path: str,
        ground_truth_filename: Optional[str] = None,
        collaborator_id: Optional[int] = None,
    ) -> int:
        """
        Inserta un registro de ground_truth y registra ground_truth_registered.
        Devuelve el ground_truth_id asignado.
        """
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO public.ground_truth (
                htr_id, ground_truth_filename, ground_truth_path
            ) VALUES (
                %(htr_id)s, %(filename)s, %(path)s
            )
            RETURNING ground_truth_id
            """,
            {
                "htr_id":   htr_id,
                "filename": ground_truth_filename,
                "path":     ground_truth_path,
            },
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
    def get_by_htr(conn, htr_id: int) -> Optional[dict]:
        cur = conn.cursor()
        cur.execute(
            "SELECT * FROM public.ground_truth WHERE htr_id = %(id)s LIMIT 1",
            {"id": htr_id},
        )
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
        model_local_path: Optional[str] = None,
        model_version: Optional[str] = None,
        collaborator_id: Optional[int] = None,
    ) -> int:
        """
        Registra un modelo de ML y registra model_registered.
        Devuelve el model_id asignado.
        """
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO public.models (
                model_name, model_url, model_local_path, model_version
            ) VALUES (
                %(name)s, %(url)s, %(local_path)s, %(version)s
            )
            RETURNING model_id
            """,
            {
                "name":       model_name,
                "url":        model_url,
                "local_path": model_local_path,
                "version":    model_version,
            },
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
    def get_by_id(conn, model_id: int) -> Optional[dict]:
        cur = conn.cursor()
        cur.execute(
            "SELECT * FROM public.models WHERE model_id = %(id)s",
            {"id": model_id},
        )
        row = cur.fetchone()
        return dict(row) if row else None

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
        cur.execute("SELECT * FROM public.models ORDER BY model_name, model_id")
        return [dict(r) for r in cur.fetchall()]
