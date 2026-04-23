"""
database/export_for_annotation.py
──────────────────────────────────
Exporta el estado actual de la BD a archivos JSON para la aplicación de anotación.

Los paleógrafos usan estos JSONs para trabajar con información actualizada
sobre documentos, abreviaturas, entidades y errores.

Uso:
  python export_for_annotation.py --collection-id 42 [--output-dir ./exports]
  htr_export_for_annotation --collection-id 42

Genera:
  collection_42_documents.json
  collection_42_abbreviations.json
  collection_42_entities.json
  collection_42_errors.json
"""

import argparse
import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from database.migration.db import get_conn, Operations


def export_documents(conn, collection_id: int) -> list[dict]:
    """
    Exporta documentos, imágenes y estado HTR de una colección.
    """
    cur = conn.cursor()
    cur.execute(
        """
        SELECT
            d.document_id,
            d.document_filename,
            d.document_path,
            ds.document_status,
            json_agg(
                json_build_object(
                    'image_id',       i.image_id,
                    'image_filename', i.image_filename,
                    'image_type',     it.image_type,
                    'page_number',    i.page_number,
                    'htr_id',         h.htr_id,
                    'htr_path',       h.htr_path
                ) ORDER BY i.page_number
            ) AS pages
        FROM public.documents d
        LEFT JOIN public.document_statuses ds ON d.document_status_id = ds.document_status_id
        LEFT JOIN public.images i ON i.document_id = d.document_id
        LEFT JOIN public.image_types it ON i.image_type_id = it.image_type_id
        LEFT JOIN public.htr h ON h.image_id = i.image_id
        WHERE d.collection_id = %(collection_id)s
        GROUP BY d.document_id, d.document_filename, d.document_path, ds.document_status
        ORDER BY d.document_filename
        """,
        {"collection_id": collection_id},
    )
    return [dict(r) for r in cur.fetchall()]


def export_abbreviations(conn, collection_id: int) -> list[dict]:
    """
    Exporta abreviaturas y sus expansiones conocidas para una colección.
    """
    cur = conn.cursor()
    cur.execute(
        """
        SELECT
            a.abbreviation_id,
            a.abbreviation,
            et.expansion_type,
            json_agg(e.expansion ORDER BY e.expansion_id) AS expansions
        FROM public.abbreviations a
        JOIN public.images i ON a.image_id = i.image_id
        JOIN public.documents d ON i.document_id = d.document_id
        LEFT JOIN public.expansion_type et ON a.expansion_type_id = et.expansion_type_id
        LEFT JOIN public.abbreviations_expansions ae ON a.abbreviation_id = ae.abbreviation_id
        LEFT JOIN public.expansions e ON ae.expansion_id = e.expansion_id
        WHERE d.collection_id = %(collection_id)s
        GROUP BY a.abbreviation_id, a.abbreviation, et.expansion_type
        ORDER BY a.abbreviation
        """,
        {"collection_id": collection_id},
    )
    return [dict(r) for r in cur.fetchall()]


def export_entities(conn, collection_id: int) -> list[dict]:
    """
    Exporta entidades nombradas detectadas en una colección con su estado de verificación.
    """
    cur = conn.cursor()
    cur.execute(
        """
        SELECT DISTINCT
            e.entity_id,
            e.entity_name,
            e.canonical_form,
            e.verified,
            array_agg(DISTINCT ety.entity_type) AS entity_types
        FROM public.entities e
        LEFT JOIN public.entities_entity_types eet ON e.entity_id = eet.entity_id
        LEFT JOIN public.entity_types ety ON eet.entity_type_id = ety.entity_type_id
        JOIN public.htr_entities he ON e.entity_id = he.entity_id
        JOIN public.htr h ON he.htr_id = h.htr_id
        JOIN public.images i ON h.image_id = i.image_id
        JOIN public.documents d ON i.document_id = d.document_id
        WHERE d.collection_id = %(collection_id)s
        GROUP BY e.entity_id, e.entity_name, e.canonical_form, e.verified
        ORDER BY e.entity_name
        """,
        {"collection_id": collection_id},
    )
    return [dict(r) for r in cur.fetchall()]


def export_errors(conn, collection_id: int) -> list[dict]:
    """
    Exporta errores y correcciones registradas para una colección.
    """
    cur = conn.cursor()
    cur.execute(
        """
        SELECT
            er.error_id,
            er.htr_word,
            er.ground_truth_word,
            er.context,
            ert.error_type,
            h.htr_id,
            h.htr_path,
            d.document_id,
            d.document_filename,
            json_agg(
                json_build_object(
                    'correction_id',   c.correction_id,
                    'corrected_word',  c.corrected_word,
                    'htr_finding',     c.htr_finding,
                    'score',           c.score
                )
            ) FILTER (WHERE c.correction_id IS NOT NULL) AS corrections
        FROM public.errors er
        JOIN public.error_type ert ON er.error_type_id = ert.error_type_id
        JOIN public.htr_errors he ON er.error_id = he.error_id
        JOIN public.htr h ON he.htr_id = h.htr_id
        JOIN public.images i ON h.image_id = i.image_id
        JOIN public.documents d ON i.document_id = d.document_id
        LEFT JOIN public.corrections c ON er.error_id = c.error_id
        WHERE d.collection_id = %(collection_id)s
        GROUP BY er.error_id, er.htr_word, er.ground_truth_word, er.context,
                 ert.error_type, h.htr_id, h.htr_path, d.document_id, d.document_filename
        ORDER BY d.document_filename, er.error_id
        """,
        {"collection_id": collection_id},
    )
    return [dict(r) for r in cur.fetchall()]


def export_collection(
    collection_id: int,
    output_dir: Path,
    collaborator_id: Optional[int] = None,
) -> dict[str, Path]:
    """
    Exporta todos los JSONs de una colección y registra la operación.
    Devuelve un dict {tipo: path_del_archivo}.
    """
    output_dir.mkdir(parents=True, exist_ok=True)
    exported_files: dict[str, Path] = {}
    timestamp = datetime.now(timezone.utc).isoformat()

    with get_conn() as conn:
        # Verificar que la colección existe
        cur = conn.cursor()
        cur.execute(
            "SELECT collection_name FROM public.collections WHERE collection_id = %(id)s",
            {"id": collection_id},
        )
        row = cur.fetchone()
        if row is None:
            raise ValueError(f"Colección {collection_id} no encontrada en la BD.")
        collection_name = row["collection_name"]

        exports = {
            "documents":     export_documents(conn, collection_id),
            "abbreviations": export_abbreviations(conn, collection_id),
            "entities":      export_entities(conn, collection_id),
            "errors":        export_errors(conn, collection_id),
        }

        for export_type, data in exports.items():
            filename = f"collection_{collection_id}_{export_type}.json"
            file_path = output_dir / filename
            payload = {
                "collection_id":   collection_id,
                "collection_name": collection_name,
                "export_type":     export_type,
                "exported_at":     timestamp,
                "n_records":       len(data),
                "data":            data,
            }
            file_path.write_text(
                json.dumps(payload, ensure_ascii=False, indent=2, default=str),
                encoding="utf-8",
            )
            exported_files[export_type] = file_path
            print(f"  ✓ {filename} — {len(data)} registros")

        # Registrar operación
        Operations.record(
            conn,
            operation_type="annotation_export_generated",
            collaborator_id=collaborator_id,
        )

    return exported_files


def main():
    parser = argparse.ArgumentParser(
        description="Exportar estado de BD a JSON para aplicación de anotación."
    )
    parser.add_argument(
        "--collection-id", type=int, required=True,
        help="ID de la colección a exportar."
    )
    parser.add_argument(
        "--output-dir", type=Path,
        default=Path("./annotation_exports"),
        help="Directorio de salida para los JSON (default: ./annotation_exports)."
    )
    parser.add_argument(
        "--collaborator-id", type=int, default=None,
        help="ID del colaborador que ejecuta la exportación."
    )
    args = parser.parse_args()

    print(f"▶ Exportando colección {args.collection_id}...")
    print(f"  Directorio de salida: {args.output_dir}")

    exported = export_collection(
        collection_id=args.collection_id,
        output_dir=args.output_dir,
        collaborator_id=args.collaborator_id,
    )

    print()
    print("═" * 50)
    print(f"  Exportación completada: {len(exported)} archivos")
    for export_type, path in exported.items():
        print(f"  {export_type}: {path}")
    print("═" * 50)


if __name__ == "__main__":
    main()
