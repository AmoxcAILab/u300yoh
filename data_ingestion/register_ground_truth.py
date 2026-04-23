"""
data_ingestion/register_ground_truth.py
────────────────────────────────────────
Script de migración: registra archivos de ground_truth vinculándolos a HTR.

Asume que:
- Las colecciones están importadas y registradas en BD
- Los archivos HTR ya fueron generados y registrados

Estructura de --ground-truth-dir:
  ground_truth/
    corpus_gt_feb_2026/
      documento_001/
        imagen_001.txt    ← texto ground_truth de la página
        imagen_002.txt
      documento_002/
        ...

El nombre de cada carpeta se compara con los document_filename en BD
para identificar el document_id. Dentro de cada carpeta, cada .txt
se parear con el htr correspondiente por nombre de archivo.

Uso:
  python register_ground_truth.py \\
    --collection-id 42 \\
    --ground-truth-dir ./data_ingestion/ground_truth/corpus_gt_feb_2026

  htr_register_ground_truth
"""

import argparse
from pathlib import Path
from typing import Optional

from database.migration.db import get_conn
from database.crud_operations import Documents, Images, HTR, GroundTruth


def register_ground_truth(
    collection_id: int,
    ground_truth_dir: Path,
    collaborator_id: Optional[int] = None,
) -> dict:
    """
    Registra archivos ground_truth para una colección.
    Devuelve un resumen con conteos.
    """
    ground_truth_dir = ground_truth_dir.resolve()
    if not ground_truth_dir.is_dir():
        raise ValueError(f"El directorio no existe: {ground_truth_dir}")

    summary = {
        "n_registered": 0,
        "n_no_htr_found": 0,
        "n_no_document_found": 0,
        "warnings": [],
    }

    with get_conn() as conn:
        documents = Documents.get_by_collection(conn, collection_id)
        documents_by_name = {d["document_filename"]: d for d in documents}

        # Recorrer carpetas de ground_truth (corresponden a documentos)
        gt_document_dirs = sorted(
            d for d in ground_truth_dir.iterdir() if d.is_dir()
        )

        for gt_document_dir in gt_document_dirs:
            doc_name = gt_document_dir.name
            doc_record = documents_by_name.get(doc_name)

            if doc_record is None:
                msg = f"Documento '{doc_name}' no encontrado en BD para colección {collection_id}"
                print(f"  ⚠ {msg}")
                summary["n_no_document_found"] += 1
                summary["warnings"].append(msg)
                continue

            document_id = doc_record["document_id"]

            # Obtener imágenes del documento para parear con GT por nombre de archivo
            images = Images.get_by_document(conn, document_id, image_type="original")
            # Índice por nombre base del archivo de imagen (sin extensión)
            images_by_stem = {
                Path(img["image_filename"]).stem: img
                for img in images
            }

            gt_files = sorted(
                f for f in gt_document_dir.iterdir()
                if f.is_file() and f.suffix.lower() == ".txt"
            )

            n_doc_registered = 0
            for gt_file in gt_files:
                # El nombre del GT coincide con el nombre de la imagen (sin extensión)
                image_stem = gt_file.stem
                image_record = images_by_stem.get(image_stem)

                if image_record is None:
                    # Intento de emparejamiento flexible: buscar prefijo común
                    matches = [
                        stem for stem in images_by_stem
                        if stem.startswith(image_stem) or image_stem.startswith(stem)
                    ]
                    if len(matches) == 1:
                        image_record = images_by_stem[matches[0]]
                    else:
                        msg = (f"No se encontró imagen para GT '{gt_file.name}' "
                               f"en documento '{doc_name}'")
                        print(f"    ⚠ {msg}")
                        summary["n_no_htr_found"] += 1
                        summary["warnings"].append(msg)
                        continue

                # Buscar HTR para esa imagen
                htr_record = HTR.get_by_image(conn, image_record["image_id"])

                if htr_record is None:
                    msg = (f"No se encontró HTR para imagen '{image_record['image_filename']}' "
                           f"en documento '{doc_name}'")
                    print(f"    ⚠ {msg}")
                    summary["n_no_htr_found"] += 1
                    summary["warnings"].append(msg)
                    continue

                # Registrar ground_truth
                GroundTruth.create(
                    conn,
                    htr_id=htr_record["htr_id"],
                    ground_truth_path=str(gt_file),
                    ground_truth_filename=gt_file.name,
                    collaborator_id=collaborator_id,
                )
                n_doc_registered += 1
                summary["n_registered"] += 1

            print(f"    {doc_name}: {n_doc_registered}/{len(gt_files)} GT registrados")

    return summary


def main():
    parser = argparse.ArgumentParser(
        description="Registrar archivos ground_truth vinculados a HTR en la BD."
    )
    parser.add_argument("--collection-id", type=int, required=True,
                        help="ID de la colección.")
    parser.add_argument("--ground-truth-dir", type=Path, required=True,
                        help="Directorio con subcarpetas de ground_truth por documento.")
    parser.add_argument("--collaborator-id", type=int, default=None)
    args = parser.parse_args()

    print(f"▶ Registrando ground_truth para colección {args.collection_id}...")
    print(f"  Directorio: {args.ground_truth_dir}")

    summary = register_ground_truth(
        collection_id=args.collection_id,
        ground_truth_dir=args.ground_truth_dir,
        collaborator_id=args.collaborator_id,
    )

    print()
    print("═" * 50)
    print(f"  GT registrados          : {summary['n_registered']}")
    print(f"  Sin HTR correspondiente : {summary['n_no_htr_found']}")
    print(f"  Documentos no en BD     : {summary['n_no_document_found']}")
    if summary["warnings"]:
        print(f"  Warnings ({len(summary['warnings'])}):")
        for w in summary["warnings"][:5]:
            print(f"    - {w}")
        if len(summary["warnings"]) > 5:
            print(f"    ... y {len(summary['warnings']) - 5} más")
    print("═" * 50)


if __name__ == "__main__":
    main()
