"""
data_ingestion/trigger_htr_transcription.py
────────────────────────────────────────────
Segunda llamada a Transkribus: usa el layout existente + modelo HTR
seleccionado según la tipografía clasificada para producir el HTR.

Flujo:
  1. Recupera el transkribus_job_id del layout (operación layout_retrieved)
     usando Operations.get_transkribus_job_id()
  2. Lee el calligraphy_type del documento (operación typography_classified)
  3. Selecciona el modelo HTR desde MODEL_DIR según calligraphy_type
  4. Llama al endpoint HTR de Transkribus con layout_job_id + modelo
  5. Registra un nuevo transkribus_job_id (para el job HTR)
     como operación htr_available con status='running'
  6. Espera a que el job HTR complete
  7. Descarga el HTR y lo guarda en:
       data_ingestion/transkribús/<collection_name>/<document_name>/<imagen_stem>_htr.txt
  8. Inserta la fila en tabla `htr` y actualiza la operación a 'completed'

Uso:
  python trigger_htr_transcription.py --image-id 42
  python trigger_htr_transcription.py --image-id 42 --model-id 7
"""

import argparse
import os
import time
from pathlib import Path

import requests

from database.migration.db import get_conn, Operations
from database.crud_operations import Images, HTR


# ── Configuración ─────────────────────────────────────────────────────
TRANSKRIBUS_API_BASE = "https://transkribus.eu/TrpServer/rest"
HTR_OUTPUT_BASE      = Path(__file__).parent / "transkribús"

POLL_INTERVAL = 20    # segundos entre consultas de estado
POLL_TIMEOUT  = 1200  # 20 minutos máximo

# Mapeo tipografía → nombre de directorio de modelo esperado en MODEL_DIR
CALLIGRAPHY_MODEL_MAP = {
    "humanistica":    "htr_humanistica",
    "cortesana":      "htr_cortesana",
    "procesal":       "htr_procesal",
    "encadenada":     "htr_encadenada",
    "gothic":         "htr_gothic",
    "default":        "htr_general",
}


def _get_session_cookie() -> dict:
    session_id = os.environ.get("TRANSKRIBUS_SESSION", "")
    if not session_id:
        raise EnvironmentError(
            "Variable de entorno 'TRANSKRIBUS_SESSION' no definida."
        )
    return {"JSESSIONID": session_id}


def _select_model(model_dir: Path, calligraphy_type: str | None) -> Path:
    """
    Elige el subdirectorio de modelo según el tipo de caligrafía.
    Si no hay match exacto, usa 'default'. Si no existe, lanza ValueError.
    """
    key = (calligraphy_type or "default").lower()
    model_name = CALLIGRAPHY_MODEL_MAP.get(key, CALLIGRAPHY_MODEL_MAP["default"])

    model_path = model_dir / model_name
    if not model_path.exists():
        # Fallback: cualquier directorio disponible en model_dir
        candidates = [d for d in model_dir.iterdir() if d.is_dir()]
        if not candidates:
            raise ValueError(
                f"No se encontró ningún modelo en: {model_dir}"
            )
        model_path = candidates[0]
        print(f"    ⚠ Modelo '{model_name}' no encontrado. Usando: {model_path.name}")

    return model_path


def _submit_htr_job(
    session_cookies: dict,
    layout_job_id: str,
    model_path: Path,
    transkribus_collection_id: int,
) -> str:
    """
    Envía el job HTR a Transkribus reutilizando el layout existente.
    Devuelve el transkribus_job_id del nuevo job HTR.
    """
    endpoint = f"{TRANSKRIBUS_API_BASE}/LA/processes/{layout_job_id}/htr"

    payload = {
        "collId":    transkribus_collection_id,
        "modelPath": str(model_path),
    }
    response = requests.post(
        endpoint,
        data=payload,
        cookies=session_cookies,
        timeout=60,
    )
    response.raise_for_status()
    data = response.json()
    return str(data.get("jobId") or data.get("id") or data["jobId"])


def _poll_job(session_cookies: dict, job_id: str) -> dict:
    """Espera a que el job complete. Devuelve estado final."""
    endpoint = f"{TRANSKRIBUS_API_BASE}/jobs/{job_id}"
    elapsed  = 0

    while elapsed < POLL_TIMEOUT:
        resp = requests.get(endpoint, cookies=session_cookies, timeout=30)
        resp.raise_for_status()
        status = resp.json()

        state = status.get("state", "CREATED")
        if state in ("FINISHED", "FAILED", "CANCELLED"):
            return status

        print(f"    [{elapsed}s] HTR job {job_id}: {state}...")
        time.sleep(POLL_INTERVAL)
        elapsed += POLL_INTERVAL

    raise TimeoutError(f"HTR job {job_id} no completó en {POLL_TIMEOUT}s.")


def _download_htr_text(
    session_cookies: dict,
    htr_job_id: str,
) -> str:
    """Descarga el texto HTR generado por Transkribus."""
    endpoint = f"{TRANSKRIBUS_API_BASE}/jobs/{htr_job_id}/result/text"
    resp = requests.get(endpoint, cookies=session_cookies, timeout=60)
    resp.raise_for_status()
    return resp.text


def trigger_htr_transcription(
    image_id: int,
    model_dir: Path | None = None,
    collaborator_id: int | None = None,
) -> dict:
    """
    Desencadena la transcripción HTR para una imagen ya con layout.

    Devuelve dict con htr_id, htr_path y transkribus_job_id.
    """
    session_cookies = _get_session_cookie()
    transkribus_collection_id = int(
        os.environ.get("TRANSKRIBUS_COLLECTION_ID", "0")
    )

    if model_dir is None:
        model_dir = Path(os.environ.get("HTR_MODELS_DIR", "data_ingestion/models"))

    with get_conn() as conn:
        # ── 1. Recuperar imagen ────────────────────────────────────
        image = Images.get_by_id(conn, image_id)
        if image is None:
            raise ValueError(f"Imagen no encontrada: image_id={image_id}")

        # ── 2. Recuperar layout_job_id ─────────────────────────────
        layout_job_id = Operations.get_transkribus_job_id(
            conn, "layout_retrieved", "image", image_id
        )
        if not layout_job_id:
            raise ValueError(
                f"No se encontró transkribus_job_id de layout_retrieved "
                f"para image_id={image_id}. "
                "Ejecuta send_to_layout_analysis.py primero."
            )
        print(f"  → layout_job_id: {layout_job_id}")

        # ── 3. Leer calligraphy_type ───────────────────────────────
        from database.crud_operations import Documents
        doc = Documents.get_by_id(conn, image["document_id"])
        calligraphy_type = (doc or {}).get("calligraphy_type")
        print(f"  → calligraphy_type: {calligraphy_type or 'desconocido'}")

        # ── 4. Seleccionar modelo ──────────────────────────────────
        model_path = _select_model(Path(model_dir), calligraphy_type)
        print(f"  → modelo: {model_path.name}")

        # ── 5. Enviar job HTR a Transkribus ────────────────────────
        htr_job_id = _submit_htr_job(
            session_cookies=session_cookies,
            layout_job_id=layout_job_id,
            model_path=model_path,
            transkribus_collection_id=transkribus_collection_id,
        )
        print(f"  ✓ HTR job enviado: {htr_job_id}")

        # ── 6. Registrar operación htr_available en running ────────
        op_id = Operations.record_and_link(
            conn,
            operation_type="htr_available",
            entity="image",
            entity_id=image_id,
            transkribus_job_id=htr_job_id,
            status="running",
            collaborator_id=collaborator_id,
        )

        # ── 7. Esperar completado ──────────────────────────────────
        print(f"  → Esperando HTR job {htr_job_id}...")
        job_status = _poll_job(session_cookies, htr_job_id)

        if job_status.get("state") != "FINISHED":
            Operations.update_status(conn, op_id, "failed")
            raise RuntimeError(
                f"HTR job {htr_job_id} terminó con estado: {job_status.get('state')}"
            )

        # ── 8. Descargar HTR ───────────────────────────────────────
        htr_text = _download_htr_text(session_cookies, htr_job_id)

        # ── 9. Construir ruta canónica ─────────────────────────────
        # transkribús/<document_id>/<imagen_stem>_htr.txt
        from database.crud_operations import Documents, Collections

        doc = Documents.get_by_id(conn, image["document_id"])
        doc_name = doc["document_filename"] if doc else str(image["document_id"])

        # Intentar obtener nombre de colección
        collection_name = str(image["document_id"])
        try:
            # Buscar collection_id a través del documento
            import psycopg2.extras
            cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
            cur.execute(
                "SELECT c.collection_name FROM collections c "
                "JOIN documents d USING (collection_id) "
                "WHERE d.document_id = %s",
                (image["document_id"],),
            )
            row = cur.fetchone()
            if row:
                collection_name = row["collection_name"]
        except Exception:
            pass

        img_stem    = Path(image["image_filename"]).stem
        htr_dir     = HTR_OUTPUT_BASE / collection_name / doc_name
        htr_dir.mkdir(parents=True, exist_ok=True)
        htr_path    = htr_dir / f"{img_stem}_htr.txt"
        htr_path.write_text(htr_text, encoding="utf-8")

        print(f"  ✓ HTR guardado: {htr_path}")

        # ── 10. Registrar HTR en tabla htr ─────────────────────────
        htr_id = HTR.create(
            conn,
            image_id=image_id,
            htr_path=str(htr_path),
            transkribus_job_id=htr_job_id,
            collaborator_id=collaborator_id,
        )

        # Actualizar operación htr_available a completed
        Operations.update_status(conn, op_id, "completed")

        return {
            "htr_id":              htr_id,
            "htr_path":            str(htr_path),
            "transkribus_job_id":  htr_job_id,
        }


def main():
    parser = argparse.ArgumentParser(
        description="Desencadenar transcripción HTR para una imagen con layout."
    )
    parser.add_argument("--image-id", type=int, required=True,
                        help="ID de la imagen en BD (debe tener layout_retrieved completado).")
    parser.add_argument("--model-dir", type=Path, default=None,
                        help="Directorio con modelos HTR (default: $HTR_MODELS_DIR).")
    parser.add_argument("--collaborator-id", type=int, default=None)
    args = parser.parse_args()

    print(f"▶ HTR transcription para image_id={args.image_id}...")
    result = trigger_htr_transcription(
        image_id=args.image_id,
        model_dir=args.model_dir,
        collaborator_id=args.collaborator_id,
    )

    print()
    print("═" * 50)
    print(f"  htr_id             : {result['htr_id']}")
    print(f"  htr_path           : {result['htr_path']}")
    print(f"  transkribus_job_id : {result['transkribus_job_id']}")
    print("═" * 50)


if __name__ == "__main__":
    main()
