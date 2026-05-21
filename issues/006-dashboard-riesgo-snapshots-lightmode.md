# Issue 006: Dashboard de Riesgo y Snapshots (Light Mode)

**Type**: AFK
**Blocked by**: issues/004-gestion-sesiones-consolidacion.md, issues/005-monitor-crisis-cortocircuito.md
**User Stories Covered**: 2, 3

## Description
Refinar la interfaz del psicólogo para que sea su "Centro de Control", priorizando la gestión de riesgos y la rapidez clínica. La interfaz debe cumplir estrictamente con el diseño Light Mode.

## Tasks
- [ ] Aplicar diseño **Light Mode** global a la aplicación Phoenix (requerimiento de diseño innegociable).
- [ ] Suscribir el LiveView del dashboard al topic PubSub `"crisis:alerts"` en `mount/3` para recibir actualizaciones en tiempo real cuando Issue 005 dispare una alerta, sin necesidad de reload ni polling.
- [ ] Crear una sección superior de "Alertas Críticas" que liste a los pacientes con `urgent_intervention: true`, actualizada reactivamente vía los eventos PubSub.
- [ ] Implementar la visualización en el detalle del paciente con jerarquía clara:
    - **Weekly Pre-Session Report** (generado por Issue 004): sección prominente al tope, visible antes de cualquier otra información.
    - **Session Snapshots** individuales: debajo del reporte semanal, colapsables, para revisión histórica.
- [ ] Añadir un "Semáforo de Estado de Ánimo" (indicadores visuales verde/amarillo/rojo) basado en el análisis de sentimiento consolidado de la tabla `trends`.
- [ ] Asegurar que el descifrado del historial de chat ocurre en el proceso LiveView del servidor (nunca en el cliente): cargar y descifrar los mensajes en `handle_event/3` solo cuando el profesional abre la vista de detalle, enviando HTML plano al browser.
- [ ] Verificar que el profesional autenticado solo puede acceder a los datos de sus propios pacientes (autorización por `professional_id`).
