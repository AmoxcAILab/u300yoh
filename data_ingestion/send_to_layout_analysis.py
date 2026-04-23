"""
data_ingestion/send_to_layout_analysis.py
──────────────────────────────────────────
Envía una imagen a la API de Transkribus para análisis de layout.

Flujo:
  1. Carga los datos de la imagen desde BD
  2. Llama al endpoint de layout analysis de Transkribus (operación asíncrona)
  3. Recibe transkribus_job_id de la respuesta inicial
  4. Registra la operación layout_retrieved con status='running'
     y el transkribus_job_id (necesario para trigger_htr_transcription.py)
  5. (Opcional) Espera a que el job complete y guarda el XML de layout localmente
  6. Actualiza la operación a status='completed'

El transkribus_job_id queda disponible en BD para que
trigger_htr_transcription.py lo recupere con Operations.get_transkribus_job_id().

Uso:
  python send_to_layout_analysis.py --image-id 42
  python send_to_layout_analysis.py --image-id 42 --wait  # espera completado
"""

import argparse
import time
from pathlib import Path

import requests

from database.migration.db import get_conn, Operations
from database.crud_operations import Images


# ── Configuración Transkribus ──────────────────────────────────────────
TRANSKRIBUS_API_BASE = "https://transkribus.eu/TrpServer/rest"
TRANSKRIBUS_COLLECTION_ID_ENV = "TRANSKRIBUS_COLLECTION_ID"
TRANSKRIBUS_CREDENTIALS_ENV   = "TRANSKRIBUS_SESSION"  # valor del cookie jsessionid

# Timeout de espera en segundos cuando se usa --wait
POLL_INTERVAL  = 15   # segundos entre consultas
POLL_TIMEOUT   = 600  # máximo de espera (10 min)

# Directorio donde se guardan los XMLs de layout localmente
LAYOUT_XML_BASE = Path(__file__).parent / "transkribús"


def _get_session_cookie() -> dict:
    """Lee el cookie de sesión Transkribus desde entorno."""
    import os
    session_id = os.environ.get(TRANSKRIBUS_CREDENTIALS_ENV, "")
    if not session_id:
        raise EnvironmentError(
            f"Variable de entorno '{TRANSKRIBUS_CREDENTIALS_ENV}' no definida. "
            "Exporta el JSESSIONID de tu sesión Transkribus."
        )
    return {"JSESSIONID": session_id}


def _get_transkribus_collection_id() -> int:
    """Lee el ID de colección Transkribus desde entorno."""
    import os
    col_id = os.environ.get(TRANSKRIBUS_COLLECTION_ID_ENV, "")
    if not col_id:
        raise EnvironmentError(
            f"Variable de entorno '{TRANSKRIBUS_COLLECTION_ID_ENV}' no definida."
        )
    return int(col_id)


def _submit_layout_job(
    session_cookies: dict,
    transkribus_collection_id: int,
    image_path: str,
) -> str:
    """
    Envía la imagen al endpoint de layout analysis.
    Devuelve el transkribus_job_id (str).
    """
    endpoint = f"{TRANSKRIBUS_API_BASE}/LA/processes"

    with open(image_path, "rb") as f:
        files = {"img": (Path(image_path).name, f, "image/jpeg")}
        payload = {
            "collId": transkribus_collection_id,
        }
        response = requests.post(
            endpoint,
            data=payload,
            files=files,
            cookies=session_cookies,
            timeout=60,
        )

    response.raise_for_status()
    data = response.json()

    # El API devuelve {"jobId": "<id>", ...} o similar
    job_id = str(data.get("jobId") or data.get("id") or data["jobId"])
    return job_id


def _poll_job_status(
    session_cookies: dict,
    transkribus_job_id: str,
    poll_interval: int = POLL_INTERVAL,
    timeout: int = POLL_TIMEOUT,
) -> dict:
    """
    Espera hasta que el job de Transkribus complete.
    Devuelve el dict de estado final del job.
    """
    endpoint = f"{TRANSKRIBUS_API_BASE}/jobs/{transkribus_job_id}"
    elapsed = 0

    while elapsed < timeout:
        response = requests.get(endpoint, cookies=session_cookies, timeout=30)
        response.raise_for_status()
        status = response.json()

        state = status.get("state", "CREATED")
        if state in ("FINISHED", "FAILED", "CANCELLED"):
            return status

        print(f"    [{elapsed}s] Job {transkribus_job_id}: {state} — esperando {poll_interval}s...")
        time.sleep(poll_interval)
        elapsed += poll_interval

    raise TimeoutError(
        f"Job {transkribus_job_id} no completó en {timeout}s."
    )


def _save_layout_xml(
    session_cookies: dict,
    transkribus_collection_id: int,
    transkribus_job_id: str,
    image: dict,
    conn,
) -> Path:
    """
    Descarga el XML de layout desde Transkribus y lo guarda localmente.
    Devuelve la ruta del archivo guardado.
    """
    # Obtener datos del documento/imagen para construir la ruta
    from database.crud_operations import Documents, Collections

    doc = Documents.get_by_id(conn, image["document_id"])
    # El XML de layout se guarda junto al HTR en transkribús/
    layout_dir = (
        LAYOUT_XML_BASE
        / str(image["document_id"])
    )
    layout_dir.mkdir(parents=True, exist_ok=True)

    img_stem = Path(image["image_filename"]).stem
    xml_path = layout_dir / f"{img_stem}_layout.xml"

    # Endpoint de resultado del job
    endpoint = f"{TRANSKRIBUS_API_BASE}/jobs/{transkribus_job_id}/result"
    response = requests.get(endpoint, cookies=session_cookies, timeout=60)
    response.raise_for_status()

    xml_path.write_bytes(response.content)
    return xml_path


def send_to_layout_analysis(
    image_id: int,
    wait: bool = False,
    collaborator_id: int | None = None,
) -> dict:
    """
    Envía la imagen a Transkribus para layout analysis.

    Devuelve dict con transkribus_job_id y operation_id.
    """
    session_cookies = _get_session_cookie()
    transkribus_collection_id = _get_transkribus_collection_id()

    with get_conn() as conn:
        image = Images.get_by_id(conn, image_id)
        if image is None:
            raise ValueError(f"Imagen no encontrada: image_id={image_id}")

        image_path = image["image_filename"]
        if not Path(image_path).exists():
            raise FileNotFoundError(f"Archivo no encontrado: {image_path}")

        print(f"  → Enviando layout analysis: {Path(image_path).name}")

        # ── Enviar job a Transkribus ───────────────────────────────
        transkribus_job_id = _submit_layout_job(
            session_cookies=session_cookies,
            transkribus_collection_id=transkribus_collection_id,
            image_path=image_path,
        )
        print(f"  ✓ Job enviado: transkribus_job_id={transkribus_job_id}")

        # ── Registrar operación con status='running' ───────────────
        op_id = Operations.record_and_link(
            conn,
            operation_type="layout_retrieved",
            entity="image",
            entity_id=image_id,
            transkribus_job_id=transkribus_job_id,
            status="running",
            collaborator_id=collaborator_id,
        )

        result = {
            "transkribus_job_id": transkribus_job_id,
            "operation_id": op_id,
            "status": "running",
        }

        # ── Esperar completado (opcional) ──────────────────────────
        if wait:
            print(f"  → Esperando completado del job {transkribus_job_id}...")
            job_status = _poll_job_status(session_cookies, transkribus_job_id)

            if job_status.get("state") == "FINISHED":
                xml_path = _save_layout_xml(
                    session_cookies, transkribus_collection_id,
                    transkribus_job_id, image, conn,
                )
                Operations.update_status(conn, op_id, "completed")
                result["status"] = "completed"
                result["layout_xml_path"] = str(xml_path)
                print(f"  ✓ Layout completado → {xml_path}")
            else:
                Operations.update_status(conn, op_id, "failed")
                result["status"] = "failed"
                print(f"  ✗ Job {transkribus_job_id} terminó con estado: {job_status.get('state')}")

    return result


def main():
    parser = argparse.ArgumentParser(
        description="Enviar imagen a Transkribus para layout analysis."
    )
    parser.add_argument("--image-id", type=int, required=True,
                        help="ID de la imagen en BD.")
    parser.add_argument("--wait", action="store_true", default=False,
                        help="Esperar a que el job complete antes de salir.")
    parser.add_argument("--collaborator-id", type=int, default=None)
    args = parser.parse_args()

    print(f"▶ Layout analysis para image_id={args.image_id}...")
    result = send_to_layout_analysis(
        image_id=args.image_id,
        wait=args.wait,
        collaborator_id=args.collaborator_id,
    )

    print()
    print("═" * 50)
    print(f"  transkribus_job_id : {result['transkribus_job_id']}")
    print(f"  operation_id       : {result['operation_id']}")
    print(f"  status             : {result['status']}")
    if "layout_xml_path" in result:
        print(f"  layout_xml_path    : {result['layout_xml_path']}")
    print("═" * 50)


if __name__ == "__main__":
    main()
