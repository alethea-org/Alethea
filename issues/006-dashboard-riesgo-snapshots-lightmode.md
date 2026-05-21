# Issue 006: Dashboard de Riesgo y Snapshots (Light Mode)

**Type**: AFK
**Blocked by**: issues/004-gestion-sesiones-consolidacion.md, issues/005-monitor-crisis-cortocircuito.md
**User Stories Covered**: 2, 3

## Description

Refinar la interfaz del psicólogo para que sea su "Centro de Control", priorizando la gestión de riesgos y la rapidez clínica. La interfaz debe cumplir estrictamente con el diseño Light Mode global y proporcionar visualizaciones reactivas en tiempo real mediante Phoenix PubSub, gráficos de emociones basados en CSS nativo y descifrado seguro en el servidor.

---

## Decisiones de Diseño Acordadas

| Decisión | Elección | Justificación |
|---|---|---|
| **Estructura de la Vista** | Un solo LiveView (`AletheaWeb.DashboardLive`) en `/dashboard` con `live_patch` a `/dashboard/patients/:id` | Navegación fluida e instantánea sin reconexión del WebSocket; mantiene el estado del PubSub. |
| **Diseño Global** | Forzar Light Mode mediante el atributo `data-theme="light"` en la etiqueta `<html>` de `root.html.heex` | Requerimiento de diseño innegociable. Uso de paleta de colores limpia (blanco, gris claro, acentos esmeralda/ámbar/carmesí). |
| **Semáforo de Estado de Ánimo** | Dinámico basado en emociones predominantes y CrisisMonitor | **Verde**: predominan `neutral`, `joy` o `surprise`. **Amarillo**: predominan `sadness`, `fear` o `disgust` o alerta `:low`. **Rojo**: predominan `anger` o alertas `:high`/`:immediate`. |
| **Consumo de Emociones** | Granular en tabla `clinical_trends` por emoción independiente | Cada emoción tiene su propio registro (joy, sadness, etc.) con score 0.0 a 1.0. Se promedia el score en una ventana móvil de los últimos 7 días. |
| **Descifrado de Chat** | Bajo demanda en el servidor en `handle_event/3` | Los mensajes se descifran usando la DEK del paciente (obtenida descifrando `EncryptionKey.encrypted_key` con la `professional_kek` en memoria del socket). El texto plano solo vive en el HTML renderizado, nunca en el cliente. |
| **Límite de Historial** | Cargar los últimos 50 mensajes por defecto | Previene sobrecarga del servidor y base de datos. Botón de "Cargar anteriores" para paginar otros 50. |
| **Alertas en Tiempo Real** | PubSub en topic `"crisis:alerts"` + Alerta Toast flotante | Notificación instantánea en banner superior/toast con el alias del paciente en crisis, además de moverlo reactivamente a la sección superior. |
| **Configuración de Horario** | Formulario en el detalle del paciente | Permite configurar `session_day_of_week` (integer 1-7) y `session_time` (time) directamente para el WeeklyReportWorker de la Issue 004. |
| **Seguridad y Auditoría** | Autorización estricta por `professional_id` + `audit_logs` | Todo acceso valida pertenencia. Se inserta registro en `audit_logs` al ver el perfil del paciente o al descifrar su chat. |

---

## Tasks

### 1. Interfaz Base y Light Mode
- [ ] Modificar `lib/alethea_web/components/layouts/root.html.heex` para incluir el atributo `data-theme="light"` en la etiqueta `<html lang="en">` para asegurar Light Mode global a través de DaisyUI.
- [ ] Diseñar el layout del dashboard general en `lib/alethea_web/live/dashboard_live.html.heex` con una estructura de dos columnas (Sidebar con listado de pacientes y alertas / Main Pane con detalle del paciente seleccionado).

### 2. Panel Superior de "Alertas Críticas" (Reactivo vía PubSub)
- [ ] En `AletheaWeb.DashboardLive.mount/3`:
  - Suscribir el proceso LiveView al topic de PubSub `"crisis:alerts"` mediante `Phoenix.PubSub.subscribe(Alethea.PubSub, "crisis:alerts")`.
  - Cargar inicialmente los pacientes del profesional que tengan `urgent_intervention == true` en un stream/lista superior de "Alertas Críticas".
- [ ] Implementar `handle_info({:crisis_alert, patient_id, level}, socket)` en el LiveView para:
  - Cargar el paciente correspondiente de la base de datos (validando que pertenezca a este profesional).
  - Mostrar una notificación flotante/toast instantánea: `put_flash(socket, :error, "¡Alerta Crítica!: El paciente #{patient.alias} ha entrado en crisis (Nivel: #{level})")`.
  - Re-streamear o mover reactivamente al paciente a la sección de "Alertas Críticas" del tope sin requerir refrescar la página.

### 3. Vista Detalle de Paciente y Jerarquía de Reportes
- [ ] Implementar la sección del **Weekly Pre-Session Report**:
  - Ubicada prominentemente en la parte superior del detalle del paciente.
  - Cargar el resumen semanal más reciente (`type: "weekly"`) de la tabla `clinical_summaries` y renderizarlo en una caja con estilo clínico de alta visibilidad (ej. fondo esmeralda/verde pastel muy suave con bordes limpios).
- [ ] Implementar el **Semáforo y Tendencia de Emociones (Gráfico CSS Nativo)**:
  - Cargar las últimas tendencias del paciente en la tabla `clinical_trends` (últimos 7 días).
  - Calcular el estado del semáforo (Verde / Amarillo / Rojo) evaluando la emoción con mayor puntuación promedio en la ventana móvil y si existe alguna alerta activa del `CrisisMonitor`.
  - Renderizar el semáforo como un indicador luminoso circular y pulsante con su color respectivo al lado del alias del paciente.
  - Renderizar un gráfico interactivo utilizando barras de progreso de DaisyUI (`<progress class="progress progress-primary ...">`) o barras CSS nativas para representar el porcentaje relativo de las 5 emociones principales (`joy`, `sadness`, `anger`, `fear`, `neutral`).
- [ ] Implementar los **Session Snapshots** históricos:
  - Renderizar una lista vertical colapsable (usando el tag `<details class="collapse bg-base-100 border border-base-300">` de DaisyUI) con los resúmenes de sesión individuales (`type: "session"`) del paciente, ordenados cronológicamente de más nuevo a más antiguo.

### 4. Descifrado de Chat Seguro en Servidor
- [ ] Añadir un botón prominentemente en el panel de detalle: "Descifrar Historial Clínico de Chat".
- [ ] Implementar `handle_event("decrypt_chat", _params, socket)` que:
  - Verifique la existencia de `socket.assigns.professional_kek` en el proceso.
  - Registre la acción en la tabla `audit_logs` con `action: "VIEW_CHAT_HISTORY"`, `professional_id: current_professional.id`, `patient_id: selected_patient.id`.
  - Recupere el registro de `EncryptionKey` del paciente del tipo `'patient'`.
  - Descifre la DEK del paciente usando la KEK del profesional: `PatientVault.decrypt_for_patient(key.encrypted_key, professional_kek)`.
  - Cargue los últimos 50 mensajes de la base de datos para este paciente.
  - Descifre el `encrypted_content` de cada mensaje en el servidor con la DEK descifrada.
  - Asigne la lista de mensajes descifrados como strings de texto plano al socket (ej. `socket.assigns.decrypted_messages`) para ser renderizados inmediatamente en el navegador en un contenedor de burbujas de chat (`chat-bubble`).
- [ ] Añadir botón de "Cargar mensajes anteriores" que realice la misma operación con un offset de 50 mensajes.

### 5. Configuración de Horario de Sesión
- [ ] Crear un formulario compacto en la sección inferior/lateral de la vista de detalle:
  - Campo de selección `session_day_of_week` (Lunes a Domingo, mapeado de 1 a 7).
  - Campo de entrada de hora `session_time` (HTML `<input type="time">`).
- [ ] Implementar `handle_event("save_session_schedule", %{"day" => day, "time" => time}, socket)` que valide los campos y actualice al paciente mediante `Accounts.update_patient_session_schedule(patient, day, time)`.

### 6. Autorización Estricta y Registro de Auditoría
- [ ] Asegurar que toda consulta de paciente (`Patient`), mensaje (`Message`), tendencia (`Trend`) y resumen (`Summary`) filtre estrictamente por `p.professional_id == ^current_professional.id`.
- [ ] Insertar automáticamente una fila en `audit_logs` cada vez que el LiveView cargue por primera vez el perfil de detalle de un paciente (`action: "VIEW_PATIENT_PROFILE"`).

---

## Archivos Involucrados

| Acción | Archivo |
|---|---|
| **MODIFY** | `lib/alethea_web/components/layouts/root.html.heex` (Añadir `data-theme="light"`) |
| **NEW** | `lib/alethea_web/live/dashboard_live.ex` (Lógica del LiveView del Centro de Control) |
| **NEW** | `lib/alethea_web/live/dashboard_live.html.heex` (Template HEEx del Dashboard) |
| **MODIFY** | `lib/alethea_web/router.ex` (Añadir ruta `live "/dashboard", DashboardLive, :index` y `live "/dashboard/patients/:id", DashboardLive, :show`) |
| **MODIFY** | `lib/alethea/accounts.ex` (Añadir función para actualizar horario del paciente e insertar logs de auditoría) |
| **NEW** | `test/alethea_web/live/dashboard_live_test.exs` (Tests del Dashboard, PubSub, autorización y descifrado seguro) |

---

## Plan de Verificación y Tests

### Tests Automatizados
- [ ] Crear `test/alethea_web/live/dashboard_live_test.exs` cubriendo:
  - **Autorización Cruzada**: Un profesional autenticado que intente acceder por URL a `/dashboard/patients/id-de-otro` debe recibir un error de no encontrado / redirección, y debe registrarse un intento fallido o no cargarse datos.
  - **Detección PubSub en Tiempo Real**: Simular el envío de un broadcast PubSub en `"crisis:alerts"` y verificar que el dashboard del psicólogo añade al paciente en tiempo real a las "Alertas Críticas" y muestra el toast de error con el alias del paciente.
  - **Descifrado Seguro**: Simular el evento `"decrypt_chat"` con la KEK del profesional en el socket, verificar que los mensajes se renderizan descifrados y que se genera el registro inmutable de auditoría correspondiente en `audit_logs`.
  - **Guardado de Horario**: Enviar el formulario de horario y verificar que los datos se persisten correctamente en la base de datos para el paciente seleccionado.
