"""
database/sync_annotations.py
─────────────────────────────
Importa archivos JSON de anotación desde el repositorio de GitHub hacia la BD.

Flujo:
  1. git pull del directorio de anotaciones (o usa el directorio actual)
  2. Detecta JSONs nuevos/modificados por SHA-256
  3. Valida el esquema del JSON
  4. Inserta/actualiza: abbreviations, expansions, errors, corrections,
     patterns, entities, descriptive_analysis
  5. Registra annotation_synced con collaborator_id del JSON
  6. Llama al rebuild de la knowledge base automáticamente

Uso:
  python sync_annotations.py [--annotations-dir DIR] [--no-kb-rebuild]
  htr_sync_annotations
"""

import argparse
import hashlib
import json
import os
import subprocess
from pathlib import Path
from typing import Optional

from database.migration.db import get_conn, Operations


# ──────────────────────────────────────────────────────────────
# VALIDACIÓN DEL ESQUEMA JSON DE ANOTACIONES
# ──────────────────────────────────────────────────────────────

REQUIRED_FIELDS = {"collaborator_id", "collection_id", "exported_at"}
ALLOWED_SECTIONS = {"abbreviations", "entities", "errors", "patterns"}


def validate_annotation_json(data: dict, file_path: Path) -> None:
    """
    Valida que el JSON de anotación tenga el esquema esperado.
    Lanza ValueError con un mensaje claro si hay problemas.
    """
    missing = REQUIRED_FIELDS - set(data.keys())
    if missing:
        raise ValueError(
            f"[{file_path.name}] Campos requeridos faltantes: {missing}\n"
            f"  El JSON debe tener: {REQUIRED_FIELDS}"
        )

    if not isinstance(data.get("collaborator_id"), int):
        raise ValueError(
            f"[{file_path.name}] 'collaborator_id' debe ser un entero."
        )

    if not isinstance(data.get("collection_id"), int):
        raise ValueError(
            f"[{file_path.name}] 'collection_id' debe ser un entero."
        )


# ──────────────────────────────────────────────────────────────
# PROCESAMIENTO DE SECCIONES DEL JSON
# ──────────────────────────────────────────────────────────────

def _get_or_create_expansion_type_id(conn, expansion_type: str) -> Optional[int]:
    cur = conn.cursor()
    cur.execute(
        "SELECT expansion_type_id FROM public.expansion_type WHERE expansion_type = %(t)s",
        {"t": expansion_type},
    )
    row = cur.fetchone()
    return row["expansion_type_id"] if row else None


def _get_or_create_entity_type_id(conn, entity_type: str) -> Optional[int]:
    cur = conn.cursor()
    cur.execute(
        "SELECT entity_type_id FROM public.entity_types WHERE entity_type = %(t)s",
        {"t": entity_type},
    )
    row = cur.fetchone()
    if row:
        return row["entity_type_id"]
    cur.execute(
        "INSERT INTO public.entity_types (entity_type) VALUES (%(t)s) RETURNING entity_type_id",
        {"t": entity_type},
    )
    return cur.fetchone()["entity_type_id"]


def _get_or_create_error_type_id(conn, error_type: str) -> Optional[int]:
    cur = conn.cursor()
    cur.execute(
        "SELECT error_type_id FROM public.error_type WHERE error_type = %(t)s",
        {"t": error_type},
    )
    row = cur.fetchone()
    return row["error_type_id"] if row else None


def process_abbreviations(conn, abbreviations: list[dict]) -> int:
    """Inserta abreviaturas y expansiones. Devuelve N registros procesados."""
    cur = conn.cursor()
    count = 0

    for abbr in abbreviations:
        abbreviation_text = abbr.get("abbreviation", "").strip()
        if not abbreviation_text:
            continue

        expansion_type_id = None
        if abbr.get("expansion_type"):
            expansion_type_id = _get_or_create_expansion_type_id(
                conn, abbr["expansion_type"]
            )

        # Verificar si ya existe (por texto)
        cur.execute(
            "SELECT abbreviation_id FROM public.abbreviations "
            "WHERE abbreviation = %(a)s LIMIT 1",
            {"a": abbreviation_text},
        )
        existing = cur.fetchone()

        if existing:
            abbreviation_id = existing["abbreviation_id"]
        else:
            cur.execute(
                "INSERT INTO public.abbreviations (abbreviation, expansion_type_id) "
                "VALUES (%(a)s, %(et_id)s) RETURNING abbreviation_id",
                {"a": abbreviation_text, "et_id": expansion_type_id},
            )
            abbreviation_id = cur.fetchone()["abbreviation_id"]
            count += 1

        # Procesar expansiones
        for expansion_text in abbr.get("expansions", []):
            expansion_text = expansion_text.strip()
            if not expansion_text:
                continue
            cur.execute(
                "SELECT expansion_id FROM public.expansions WHERE expansion = %(e)s LIMIT 1",
                {"e": expansion_text},
            )
            row = cur.fetchone()
            if row:
                expansion_id = row["expansion_id"]
            else:
                cur.execute(
                    "INSERT INTO public.expansions (expansion) VALUES (%(e)s) "
                    "RETURNING expansion_id",
                    {"e": expansion_text},
                )
                expansion_id = cur.fetchone()["expansion_id"]

            cur.execute(
                "INSERT INTO public.abbreviations_expansions (abbreviation_id, expansion_id) "
                "VALUES (%(a_id)s, %(e_id)s) ON CONFLICT DO NOTHING",
                {"a_id": abbreviation_id, "e_id": expansion_id},
            )

    return count


def process_entities(conn, entities: list[dict]) -> int:
    """Inserta o actualiza entidades. Devuelve N registros procesados."""
    cur = conn.cursor()
    count = 0

    for ent in entities:
        entity_name = ent.get("entity_name", "").strip()
        if not entity_name:
            continue

        cur.execute(
            "SELECT entity_id FROM public.entities WHERE entity_name = %(n)s LIMIT 1",
            {"n": entity_name},
        )
        existing = cur.fetchone()

        if existing:
            entity_id = existing["entity_id"]
            # Actualizar verified si cambió
            if ent.get("verified") is not None:
                cur.execute(
                    "UPDATE public.entities SET verified = %(v)s, "
                    "canonical_form = COALESCE(%(cf)s, canonical_form) "
                    "WHERE entity_id = %(id)s",
                    {
                        "v":  ent["verified"],
                        "cf": ent.get("canonical_form"),
                        "id": entity_id,
                    },
                )
        else:
            cur.execute(
                "INSERT INTO public.entities (entity_name, canonical_form, verified) "
                "VALUES (%(n)s, %(cf)s, %(v)s) RETURNING entity_id",
                {
                    "n":  entity_name,
                    "cf": ent.get("canonical_form"),
                    "v":  ent.get("verified", False),
                },
            )
            entity_id = cur.fetchone()["entity_id"]
            count += 1

        # Procesar tipos de entidad
        for entity_type in ent.get("entity_types", []):
            entity_type_id = _get_or_create_entity_type_id(conn, entity_type)
            if entity_type_id:
                cur.execute(
                    "INSERT INTO public.entities_entity_types (entity_id, entity_type_id) "
                    "VALUES (%(e_id)s, %(et_id)s) ON CONFLICT DO NOTHING",
                    {"e_id": entity_id, "et_id": entity_type_id},
                )

    return count


def process_errors(conn, errors: list[dict]) -> int:
    """Inserta errores y correcciones. Devuelve N registros procesados."""
    cur = conn.cursor()
    count = 0

    for err in errors:
        htr_word = err.get("htr_word", "").strip()
        if not htr_word:
            continue

        error_type_id = None
        if err.get("error_type"):
            error_type_id = _get_or_create_error_type_id(conn, err["error_type"])

        # Necesitamos un descriptive_analysis_id — buscamos uno existente para el htr_id
        htr_id = err.get("htr_id")
        cur.execute(
            "SELECT descriptive_analysis_id FROM public.descriptive_analysis "
            "WHERE htr_id = %(htr_id)s ORDER BY analyzed_at DESC LIMIT 1",
            {"htr_id": htr_id},
        )
        da_row = cur.fetchone()
        descriptive_analysis_id = da_row["descriptive_analysis_id"] if da_row else None

        cur.execute(
            """
            INSERT INTO public.errors (
                descriptive_analysis_id, error_type_id,
                htr_word, ground_truth_word, context
            ) VALUES (
                %(da_id)s, %(et_id)s,
                %(htr_word)s, %(gt_word)s, %(ctx)s
            )
            RETURNING error_id
            """,
            {
                "da_id":   descriptive_analysis_id,
                "et_id":   error_type_id,
                "htr_word": htr_word,
                "gt_word":  err.get("ground_truth_word", ""),
                "ctx":      err.get("context", ""),
            },
        )
        error_id = cur.fetchone()["error_id"]
        count += 1

        # Vincular al HTR
        if htr_id:
            cur.execute(
                "INSERT INTO public.htr_errors (htr_id, error_id) "
                "VALUES (%(h)s, %(e)s) ON CONFLICT DO NOTHING",
                {"h": htr_id, "e": error_id},
            )

        # Procesar correcciones
        for corr in err.get("corrections", []):
            corrected_word = corr.get("corrected_word", "").strip()
            if corrected_word:
                cur.execute(
                    "INSERT INTO public.corrections "
                    "(error_id, htr_finding, corrected_word, score) "
                    "VALUES (%(e_id)s, %(finding)s, %(word)s, %(score)s)",
                    {
                        "e_id":    error_id,
                        "finding": corr.get("htr_finding", ""),
                        "word":    corrected_word,
                        "score":   corr.get("score", 0),
                    },
                )

    return count


# ──────────────────────────────────────────────────────────────
# TRACKING DE ARCHIVOS PROCESADOS (SHA-256)
# ──────────────────────────────────────────────────────────────

def _sha256(file_path: Path) -> str:
    h = hashlib.sha256()
    h.update(file_path.read_bytes())
    return h.hexdigest()


def _load_processed_registry(registry_path: Path) -> dict[str, str]:
    """Carga el registro de archivos ya procesados {filename: sha256}."""
    if registry_path.exists():
        return json.loads(registry_path.read_text(encoding="utf-8"))
    return {}


def _save_processed_registry(registry_path: Path, registry: dict[str, str]) -> None:
    registry_path.write_text(
        json.dumps(registry, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )


# ──────────────────────────────────────────────────────────────
# SINCRONIZACIÓN PRINCIPAL
# ──────────────────────────────────────────────────────────────

def sync_annotations(
    annotations_dir: Path,
    rebuild_kb: bool = True,
) -> dict[str, int]:
    """
    Sincroniza anotaciones desde el directorio de JSONs.
    Devuelve resumen: {tipo: n_registros_procesados}.
    """
    registry_path = annotations_dir / ".sync_registry.json"
    processed = _load_processed_registry(registry_path)
    summary: dict[str, int] = {
        "abbreviations": 0,
        "entities": 0,
        "errors": 0,
        "json_files_processed": 0,
    }

    json_files = sorted(annotations_dir.glob("*.json"))
    if not json_files:
        print(f"⚠ No se encontraron archivos JSON en {annotations_dir}")
        return summary

    for json_path in json_files:
        if json_path.name.startswith("."):
            continue

        current_sha = _sha256(json_path)
        if processed.get(json_path.name) == current_sha:
            print(f"  — {json_path.name} sin cambios, omitiendo.")
            continue

        print(f"  ▶ Procesando {json_path.name}...")

        try:
            data = json.loads(json_path.read_text(encoding="utf-8"))
            validate_annotation_json(data, json_path)
        except (json.JSONDecodeError, ValueError) as e:
            print(f"  ✗ Error en {json_path.name}: {e}")
            continue

        collaborator_id = data["collaborator_id"]

        with get_conn() as conn:
            n_abbr = process_abbreviations(
                conn, data.get("abbreviations", [])
            )
            n_ent = process_entities(
                conn, data.get("entities", [])
            )
            n_err = process_errors(
                conn, data.get("errors", [])
            )

            Operations.record(
                conn,
                operation_type="annotation_synced",
                collaborator_id=collaborator_id,
            )

        summary["abbreviations"] += n_abbr
        summary["entities"] += n_ent
        summary["errors"] += n_err
        summary["json_files_processed"] += 1

        processed[json_path.name] = current_sha
        print(f"    ✓ {n_abbr} abreviaturas, {n_ent} entidades, {n_err} errores")

    _save_processed_registry(registry_path, processed)

    if rebuild_kb and summary["json_files_processed"] > 0:
        print("\n  ▶ Reconstruyendo knowledge base...")
        try:
            from data_ingestion.build_knowledge_base import build_knowledge_base
            build_knowledge_base()
        except ImportError:
            print("  ⚠ build_knowledge_base no disponible aún — omitiendo rebuild.")
        except Exception as e:
            print(f"  ✗ Error en rebuild KB: {e}")

    return summary


def pull_and_sync(
    annotations_dir: Path,
    rebuild_kb: bool = True,
) -> dict[str, int]:
    """
    Hace git pull del directorio de anotaciones y luego sincroniza.
    Si git no está disponible o falla, continúa con el estado local.
    """
    print(f"▶ git pull en {annotations_dir}...")
    try:
        result = subprocess.run(
            ["git", "pull"],
            cwd=annotations_dir,
            capture_output=True,
            text=True,
            timeout=60,
        )
        if result.returncode == 0:
            print(f"  ✓ {result.stdout.strip()}")
        else:
            print(f"  ⚠ git pull retornó {result.returncode}: {result.stderr.strip()}")
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        print(f"  ⚠ No se pudo hacer git pull: {e}. Usando estado local.")

    return sync_annotations(annotations_dir, rebuild_kb=rebuild_kb)


def main():
    parser = argparse.ArgumentParser(
        description="Sincronizar anotaciones JSON desde GitHub hacia la BD."
    )
    parser.add_argument(
        "--annotations-dir", type=Path,
        default=Path("./annotation_exports"),
        help="Directorio de archivos JSON de anotación."
    )
    parser.add_argument(
        "--no-kb-rebuild", action="store_true",
        help="No reconstruir la knowledge base después de sincronizar."
    )
    parser.add_argument(
        "--no-git-pull", action="store_true",
        help="No hacer git pull antes de sincronizar."
    )
    args = parser.parse_args()

    if args.no_git_pull:
        summary = sync_annotations(
            args.annotations_dir,
            rebuild_kb=not args.no_kb_rebuild,
        )
    else:
        summary = pull_and_sync(
            args.annotations_dir,
            rebuild_kb=not args.no_kb_rebuild,
        )

    print()
    print("═" * 50)
    print("  Sincronización completada")
    print(f"  Archivos procesados  : {summary['json_files_processed']}")
    print(f"  Abreviaturas nuevas  : {summary['abbreviations']}")
    print(f"  Entidades nuevas     : {summary['entities']}")
    print(f"  Errores nuevos       : {summary['errors']}")
    print("═" * 50)


if __name__ == "__main__":
    main()
