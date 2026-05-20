# Issue 006: Dashboard de Riesgo y Snapshots (Light Mode)

**Type**: AFK
**Blocked by**: issues/004-gestion-sesiones-consolidacion.md, issues/005-monitor-crisis-cortocircuito.md
**User Stories Covered**: 2, 3

## Description
Refinar la interfaz del psicólogo para que sea su "Centro de Control", priorizando la gestión de riesgos y la rapidez clínica. La interfaz debe cumplir estrictamente con el diseño Light Mode.

## Tasks
- [ ] Aplicar diseño **Light Mode** global a la aplicación Phoenix.
- [ ] Crear una sección superior de "Alertas Críticas" que liste a los pacientes con flags de intervención urgente.
- [ ] Implementar la visualización del **Snapshot** de 4 líneas en el detalle del paciente (consulta directa a la tabla de resúmenes).
- [ ] Añadir un "Semáforo de Estado de Ánimo" (indicadores visuales verde/amarillo/rojo) basado en el análisis de sentimiento consolidado.
- [ ] Asegurar que el historial de chat se descifra en tiempo real solo cuando el profesional abre la vista de detalle.
