# Informe de pruebas — Alethea

Fecha de ejecución: 2026-11-10 · Commit: `9130c77` (`main`) · Entorno: desarrollo local (Phoenix en `:4001`, PostgreSQL local, Ollama con `phi4-mini`), datos 100 % sintéticos.

Actualizado el 2026-11-10 sobre el commit `e42a980` (`main`): la suite automatizada se volvió a ejecutar completa, se agregó el caso M-24 y se registraron las correcciones #496, #497 y #498.

## 1. Casos de prueba clave

### 1.1 Automatizados (ExUnit)

La suite cubre el dominio, los workers y la interfaz LiveView. Áreas principales y cantidad de tests (conteo al commit `9130c77`; el total actual está en la sección 2):

| Área | Tests | Qué verifica (ejemplos) |
| --- | --- | --- |
| Interfaz web (`test/alethea_web`) | 448 | Dashboard, gestión de pacientes, triggers (crear, editar, eliminar), revisión clínica, controladores y plugs de sesión |
| Registro clínico (`clinical_record`) | 429 | Versiones inmutables E-O-R-C, evidencia anclada a `message_id`, borradores que nunca cuentan como evidencia |
| IA (`ai`) | 396 | Sanitizado de PII antes de llamar a modelos externos, bloqueo de respuestas diagnósticas o prescriptivas, enrutamiento de modelos, reintentos |
| Workers Oban (`jobs`) | 260 | Pipeline asíncrono de mensajes, idempotencia, envío de triggers programados |
| Telegram (`telegram`) | 185 | Webhook, vinculación del paciente, ritmo de envío por chat |
| Base (`foundation`) | 133 | Cifrado por paciente (DEK), configuración de runtime |
| Triggers (`triggers`) | 123 | Cooldown, disparo único, límite de reactivos activos, archivado, permisos entre profesionales |
| Clínico (`clinical`) | 61 | Mensajes, resúmenes, tendencias |
| Cuentas (`accounts`) | 36 | Identidad del profesional, auditoría |
| Alertas (`alerts`) | 28 | Detección de crisis y mensaje de contención |

### 1.2 Manuales (web del profesional)

Ejecutados con un navegador automatizado (Playwright) sobre la app real. La evidencia está en `docs/qa/evidence-2026-11-10/`.

| ID | Caso | Resultado | Observación |
| --- | --- | --- | --- |
| M-01 | Landing pública | Pasa | |
| M-02 | Ruta protegida sin sesión redirige a login | Pasa | |
| M-03 | Registro de profesional | Pasa | Tras registrarse lleva a `/login` en vez de entrar directo (ver O1) |
| M-04 | Registro con email duplicado | Pasa | No crea una segunda cuenta |
| M-05 | Login con contraseña incorrecta | Pasa | Muestra "incorrectos" |
| M-06 | Login correcto | Pasa | |
| M-07 | Crear paciente | Pasa | |
| M-08 | Crear paciente con alias vacío o solo espacios | Pasa con bug | Rechaza, pero el mensaje está en inglés (B3) |
| M-09 | Abrir ficha del paciente desde el dashboard | Pasa | |
| M-10 | Invitar paciente (código de 6 dígitos) | Pasa | |
| M-11 | Abrir pantalla de triggers | Pasa | |
| M-12 | Generar vista previa de trigger programado | Pasa | ~5,5 s con modelo local |
| M-13 | Aprobar trigger programado | Pasa | Aparece en "Triggers programados" |
| M-14 | Trigger programado con fecha pasada | Pasa con bug | Al aprobar lo rechaza ("debe ser en el futuro"), pero antes deja generar la vista previa (B2) |
| M-15 | Crear y aprobar trigger reactivo | Pasa | ~3,9 s |
| M-16 | Editar trigger reactivo (cooldown) | Pasa | |
| M-17 | Eliminar trigger reactivo | Pasa | |
| M-18 | Eliminar trigger programado y recargar | Pasa | No reaparece |
| M-19 | Configuración del bot: mensaje de contención | Pasa | |
| M-20 | Notas clínicas y consulta cargan | Pasa | |
| M-21 | Otro profesional intenta abrir un paciente ajeno | Pasa | Redirige a su lista; no ve datos ajenos |
| M-22 | Cerrar sesión | Pasa | |
| M-23 | Modelo de IA caído al generar vista previa | Pasa | Muestra "No se pudo generar la vista previa. Inténtalo nuevamente." sin romper la pantalla |
| M-24 | Notas clínicas con 25 notas: carga paginada y scroll | Pasa | Muestra 20; al bajar dentro del panel carga las 5 restantes y oculta "Cargar más" (commit `e42a980`) |

### 1.3 Manuales (lado del paciente, Telegram)

Ejecutados a mano en producción con un teléfono vinculado a un paciente de prueba.

| ID | Caso | Pasos | Resultado esperado | Resultado |
| --- | --- | --- | --- | --- |
| T-01 | Vincular paciente | Enviar al bot el código de 6 dígitos de M-10 | El bot confirma y el dashboard muestra el paciente conectado | Pasa |
| T-02 | Mensaje diario | Contar cómo fue el día | Respuesta neutral, sin diagnósticos ni consejos; el mensaje aparece en el registro | Pasa |
| T-03 | Crisis | Enviar "Ya no puedo más, estoy al límite" | Llega el mensaje de contención, se pausan los triggers y el dashboard marca intervención urgente | Pasa con bug (B0, corregido en #496) |
| T-04 | Trigger reactivo | Con el reactivo "Habla de su padre" activo, escribir "Hoy hablé con mi papá" | La respuesta retoma la instrucción del trigger | Pasa |
| T-05 | Cooldown | Repetir T-04 enseguida | No vuelve a disparar dentro del cooldown | Pasa |
| T-06 | Trigger programado | Programar uno para dentro de 5 minutos | Llega a la hora indicada | Pasa |

## 2. Resultado de ejecución

| Suite | Total | Pasan | Fallan | Omitidos | Duración |
| --- | --- | --- | --- | --- | --- |
| ExUnit (`mix test`, commit `e42a980`) | 2910 | 2905 | 0 | 5 | 55,8 s |
| Manuales web | 24 | 24 (2 con bug menor) | 0 | 0 | — |
| Manuales Telegram | 6 | 6 (1 con bug, ya corregido) | 0 | 0 | — |

Los `[error]` que aparecen en el log de `mix test` son provocados a propósito por los tests (por ejemplo, escritura no autorizada en una tabla ETS protegida) y no son fallas.

## 3. Bugs detectados (priorizados)

Severidad: **Alta** = bloquea un flujo crítico o afecta datos clínicos; **Media** = resultado incorrecto con mitigación; **Baja** = UX o redacción.

### Encontrados en esta ejecución

| ID | Severidad | Descripción | Evidencia |
| --- | --- | --- | --- |
| B0 | Alta | Si el profesional no configuró su mensaje de contención, la crisis responde con el texto por defecto de `config/runtime.exs`, que trae líneas de ayuda de **Chile** (Salud Responde, ACHS, SAMU 131) en un producto dirigido a Argentina. Un paciente en crisis recibe números que no le sirven. **Corregido en #496:** el mensaje ahora indica el Centro de Asistencia al Suicida (0800 345 1435) y el 911. | T-03, mensaje recibido en Telegram |
| B1 | Media | Con el modelo local (`phi4-mini`) y una instrucción ambigua, la vista previa inventa un nombre de paciente ("Estimada Ana") y una firma ("Su Terapeuta Alethea"). Lo mitiga que el profesional debe aprobar el texto antes de enviarlo. | `M-14.png`, `M-14b.png` |
| B2 | Baja | La fecha pasada recién se valida al aprobar; antes deja generar la vista previa y gasta una llamada al modelo. | `M-14b.png` |
| B3 | Baja | El error de alias vacío se muestra en inglés ("can't be blank") en una interfaz en español. | `M-08.png` |
| O1 | Observación | Tras registrarse, el profesional vuelve a `/login` y tiene que ingresar de nuevo. Confirmar si es intencional. | `M-03.png` |

### Detectados durante el desarrollo

| Severidad | Descripción | Estado |
| --- | --- | --- |
| Alta | El trigger reactivo se detectaba pero la respuesta guiada no lo entregaba al paciente | Corregido (#492) |
| Alta | El resumen semanal guardaba un JSON Schema y mostraba una alerta clínica falsa | Corregido (#360) |
| Alta | Envíos repetidos registraban versiones E-O-R-C inmutables duplicadas | Corregido (#372) |
| Alta | Un paciente marcado con intervención urgente no podía volver a su estado normal, y sus triggers programados quedaban pausados para siempre | Corregido (#497): alta y baja del riesgo desde una nota clínica |
| Alta | Si llegaba una crisis justo después de dar de baja el riesgo, la marca de intervención urgente podía no guardarse | Corregido (#497) |
| Media | El matcher de triggers reactivos solo ve la ráfaga actual de mensajes, no el contexto de la conversación | Abierto (#493) |
| Media | Notas clínicas, sesiones anteriores, triggers y fuentes de evidencia cargaban la lista completa de una vez | Corregido (#498): carga paginada de a 20 con scroll |
| Media | No había forma de eliminar triggers programados ni reactivos | Corregido (#495) |
| Media | En producción no había indicador de carga y los clics parecían no responder | Corregido (#494) |
| Baja | Tests de LiveView fallaban de forma intermitente bajo carga | Corregido (#376) |
