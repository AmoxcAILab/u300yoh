# Proceso de ingestión de datos

## Visión general

```
Fase 1 — Registro de colección (register_collection.py)
  Input:  {collection_dir}/{collection}.metadata
  Output: fila en collections + operación collection_registered
          Si collection_Notas ≠ vacío → nota + notes_collections + note_created

  Fase 1a — Registro de documentos (loop interno)
    Input:  {collection_dir}/documentos/*.metadata
    Output: fila en documents con campos archivísticos + operación document_registered
            Si document_Notas ≠ vacío → nota + notes_documents + note_created

  Fase 1b — Registro de imágenes (loop interno)
    Input:  archivos de imagen en el directorio del documento
    Output: fila en images + operación image_registered

Fase 2 — Importación de imágenes crudas (import_collection.py) [ITERACIÓN FUTURA]
  Input:  directorio con imágenes crudas
  Output: imágenes copiadas a raw_collections_images/ + operación images_downloaded
```

---

## Estructura de carpetas esperada

El script recibe un directorio de colección. Dentro debe haber exactamente un `*.metadata` (datos de la colección) y una subcarpeta `documentos/` con uno o más `*.metadata` por documento:

```
{collection_dir}/
  AGN_marina.metadata          ← metadatos de la colección
  documentos/
    AGN_Marina_v001_exp135.metadata
    AGN_Marina_v001_exp136.metadata
    ...
```

Ejemplo de invocación:

```bash
htr_register_collection --collection-dir data_ingestion/metadata/collections/AGN_marina/
```

---

## Flujo detallado de register_collection.py

```python
def register_collection(collection_dir, collaborator_id):

    # 1. Encontrar {collection}.metadata en collection_dir
    metadata_file = next(Path(collection_dir).glob('*.metadata'))
    collection_data = parse_collection_metadata(metadata_file)

    # 2. Extraer nota si existe
    col_nota = collection_data.pop('collection_Notas', None)

    # 3. Insertar colección; los campos FK usan nombres → el método resuelve a UUID
    collection_id = Collections.create(conn, **collection_data)

    # 4. Si hay nota → crearla y vincularla directamente a la colección
    if col_nota:
        note_id = Notes.create(conn, col_nota)
        Notes.link_to_collection(conn, note_id, collection_id)   # notes_collections
        op_id = Operations.create(conn, 'note_created', collaborator_id)
        Notes.link_to_operation(conn, note_id, op_id)            # notes_operation

    # 5. Por cada documento en documentos/
    documentos_dir = Path(collection_dir) / 'documentos'
    for doc_metadata_file in sorted(documentos_dir.glob('*.metadata')):
        document_data = parse_document_metadata(doc_metadata_file)

        # 5a. Extraer nota antes de procesar
        nota_texto = document_data.pop('document_Notas', None)

        # 5b. Detectar campos no existentes como columnas y añadirlos dinámicamente
        EXCLUDED = {'document_id', 'document_Notas', 'collection_id', 'document_status'}
        for field_name in list(document_data.keys()):
            if field_name not in EXCLUDED and not column_exists('documents', field_name):
                conn.execute(
                    f"ALTER TABLE public.documents ADD COLUMN IF NOT EXISTS {field_name} TEXT"
                )

        # 5c. Insertar documento
        document_id = Documents.create(conn, collection_id, **document_data)

        # 5d. Si había document_Notas → crear nota vinculada directamente al documento
        if nota_texto:
            note_id = Notes.create(conn, nota_texto)
            Notes.link_to_document(conn, note_id, document_id)  # notes_documents
            op_id = Operations.create(conn, 'note_created', collaborator_id)
            Notes.link_to_operation(conn, note_id, op_id)       # notes_operation

        # 6. Registrar imágenes del documento
        for image_file in sorted(doc_images_dir.glob('*.jpg')):
            Images.create(conn, document_id, image_file, page_number=N)
```

---

## Formato de archivos .metadata

### {coleccion}.metadata

Una línea por campo, separador `: ` (los espacios de alineación se ignoran al hacer `strip()`).
Los campos FK usan **nombres legibles**, no IDs ni UUIDs — el script los resuelve via lookup en los catálogos.
Los campos generados por la BD (`collection_id`) se omiten.

```
collection_name                : Marina
collection_path                :
collection_type                : AGN
collection_status              : new
collection_url                 :
collection_archival_institution: Archivo General de la Nación
```

Resoluciones que hace el script:
- `collection_type` → `SELECT collection_type_id FROM collection_types WHERE collection_type = $1`
- `collection_status` → `SELECT collection_status_id FROM collection_statuses WHERE collection_status = $1`
- `collection_archival_institution` → `SELECT archival_institution_id FROM archival_institutions WHERE archival_institution_name = $1`

### {documento}.metadata

Misma estructura. El `collection_id` no se incluye (se pasa como argumento en tiempo de ejecución).
El campo `document_Notas` se extrae **antes** del INSERT y se crea como nota independiente.

```
document_name             : AGN_Marina_v001_exp135
document_path             :
document_status           : new
document_url              :
document_archive          : Archivo General de la Nación
document_Fondo            : Marina
...
document_Notas            : Las fojas 4 y 5 se encuentran en blanco.
```

Columnas a **ignorar** al parsear los archivos `doc.{tipo}.metadata` (son referencia, no van a BD):
- `separator`
- `correspondencia_metadatos_archivo`
- `ejemplo_metadatos_archivo`
- `notas`

---

## Ejemplos de archivos .metadata

### Colecciones

**AGN_marina/AGN_marina.metadata**
```
collection_name                : Marina
collection_path                :
collection_type                : AGN
collection_status              : new
collection_url                 :
collection_archival_institution: Archivo General de la Nación
```

**AMP_actas_cabildo/AMP_actas_cabildo.metadata**
```
collection_name                : Actas de Cabildo
collection_path                :
collection_type                : AMP
collection_status              : new
collection_url                 :
collection_archival_institution: Archivo Municipal de Puebla
```

**AMP_memoria_urbana/AMP_memoria_urbana.metadata**
```
collection_name                : Memoria Urbana
collection_path                :
collection_type                : AMP
collection_status              : new
collection_url                 :
collection_archival_institution: Archivo Municipal de Puebla
```

**BP_manuscritos/BP_manuscritos.metadata**
```
collection_name                : Manuscritos
collection_path                :
collection_type                : BP
collection_status              : new
collection_url                 :
collection_archival_institution: Biblioteca Palafoxiana
```

---

### Documentos — AGN

**AGN_marina/documentos/AGN_Marina_v001_exp135.metadata**
```
document_name             : AGN_Marina_v001_exp135
document_path             :
document_status           : new
document_url              :
document_archive          : Archivo General de la Nación
document_Fondo            : Marina
document_Volumen          : v001
document_Caja             :
document_Legajo           : 107
document_Expediente       : 135
document_Fecha_creacion   : 11/10/1578
document_Año_creacion     : 1578
document_Lugar_creacion   : Tabasco
document_Soporte          : Papel
document_Descripcion      : Registro de las mercaderías que transportaría desde el puerto de Tabasco...
document_Rango_fojas      : 1-3
document_Num_pags         :
document_Num_pags_escritas: 6
document_Notas            : Las fojas 4 y 5 se encuentran en blanco.
```

### Documentos — AMP (Actas de Cabildo)

**AMP_actas_cabildo/documentos/AMP_AC_v013_doc145.metadata**
```
document_name             : AMP_AC_v013_doc145
document_path             :
document_status           : new
document_url              :
document_archive          : Archivo Municipal de Puebla
document_Fondo            : Actas de Cabildo siglo XVII
document_Volumen          : v013
document_Tomo             :
document_Legajo           :
document_Documento        : doc145
document_Fecha_creacion   : 25/10/1599
document_Año_creacion     : 1599
document_Lugar_creacion   : Puebla (Puebla), México
document_Descripcion      :
document_Rango_fojas      : 82f
document_Num_pags         :
document_Num_pags_escritas: 1
document_Notas            :
```

### Documentos — AMP (Memoria Urbana)

**AMP_memoria_urbana/documentos/AMP_MU_t151_leg1494.metadata**
```
document_name             : AMP_MU_t151_leg1494
document_path             :
document_status           : new
document_url              :
document_archive          : Archivo Municipal de Puebla
document_Fondo            : Memoria Urbana 1519-1910
document_Volumen          :
document_Tomo             : t151
document_Legajo           : leg1494
document_Documento        :
document_Fecha_creacion   : 14/03/1656
document_Año_creacion     : 1656
document_Lugar_creacion   : Puebla (Puebla), México
document_Descripcion      : Conducción de 300 quintales de plomo para la Nueva Veracruz...
document_Rango_fojas      : 121f-131f
document_Num_pags         :
document_Num_pags_escritas: 21
document_Notas            :
```

### Documentos — BP

**BP_manuscritos/documentos/BP_CM_32386_007.metadata**
```
document_name             : BP_CM_32386_007
document_path             :
document_status           : new
document_url              :
document_archive          : Biblioteca Palafoxiana
document_Fondo            : Colección de Manuscritos
document_Volumen          : 32386
document_Expediente       : 007
document_Fecha_creacion   : 26/07/1697
document_Año_creacion     : 1697
document_Lugar_creacion   : Veracruz, México
document_Descripcion      :
document_Rango_fojas      :
document_Num_pags         :
document_Num_pags_escritas: 8
document_Notas            :
```

### Documentos — AGI

**AGI_{coleccion}/documentos/AGI_CONTRATACION_5225A_N1R4.metadata**
```
document_name             : AGI_CONTRATACION_5225A_N1R4
document_path             :
document_status           : new
document_url              : https://pares.mcu.es/...
document_archive          : Archivo General de Indias
document_Titulo           : ANSELMO LOPEZ RAMIREZ
document_Signatura        : CONTRATACION,5225A,N.1,R.4
document_Productores      : Casa de la Contratación de las Indias (España)
document_Fecha_creacion   : 1576-06-08
document_Año_creacion     : 1576
document_Indices_de_Descripcion: Fuentelencina (Guadalajara, España); Nueva España (virreinato)
document_Lugar_creacion   :
document_Soporte          : 1 Expediente
document_Descripcion      : Expediente de información y licencia de pasajero a indias de Anselmo López Ramírez...
document_Num_pags         :
document_Num_pags_escritas:
document_Notas            :
```

---

## Convenciones de nombrado

| Institución | Patrón | Ejemplo |
|---|---|---|
| AGN Marina | `AGN_Marina_v{vol}_exp{exp}` | `AGN_Marina_v001_exp135` |
| AMP Actas Cabildo | `AMP_AC_v{vol}_doc{doc}` | `AMP_AC_v013_doc145` |
| AMP Memoria Urbana | `AMP_MU_t{tomo}_leg{legajo}` | `AMP_MU_t151_leg1494` |
| BP Manuscritos | `BP_CM_{vol}_{exp}` | `BP_CM_32386_007` |
| AGI | `AGI_{seccion}_{signatura}` | `AGI_CONTRATACION_1089_N8` |

---

## Prerrequisitos para el primer despliegue

```bash
# 1. Entrar al entorno Nix
nix develop infrastructure/amoxcailab_flake.nix

# 2. Inicializar BD
htr_db_init
htr_db_schema database/schema.sql    # aplica DDL + seed (roles, catálogos, amoxcailab)
htr_db_status

# 3. Verificar usuario admin
psql -c "SELECT c.collaborator_name, r.role_name
         FROM collaborators c
         JOIN collaborators_roles cr USING(collaborator_id)
         JOIN roles r USING(role_id);"

# 4. Configurar colaborador en env
export HTR_COLLABORATOR_ID=$(psql -tAc "
    SELECT collaborator_id FROM collaborators
    WHERE collaborator_name='amoxcailab'")

# 5. Registrar colección + documentos + imágenes
htr_register_collection \
  --collection-dir data_ingestion/metadata/collections/AGN_marina/
```

---

## Verificación post-registro

```sql
-- Colección registrada
SELECT collection_name, ct.collection_type, cs.collection_status
FROM collections c
JOIN collection_types ct USING (collection_type_id)
JOIN collection_statuses cs USING (collection_status_id);

-- Documentos con campos archivísticos
SELECT document_name, document_Fondo, document_Volumen, document_Expediente
FROM v_documents_agn;

-- Notas registradas y sus documentos
SELECT n.note, d.document_name
FROM notes n
JOIN notes_documents nd USING (note_id)
JOIN documents d USING (document_id);

-- Operaciones del proceso de ingestión
SELECT ot.operation_type, o.logged_at, o.status
FROM operations o
JOIN operation_types ot USING (operation_type_id)
ORDER BY o.logged_at;
```
