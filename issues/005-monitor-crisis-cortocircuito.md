# Issue 005: Monitor de Crisis y Cortocircuito (Bypass)

**Type**: AFK
**Blocked by**: issues/003-integracion-meta-api-ia-reflexion.md
**User Stories Covered**: 7

## Description
Implementar una capa de seguridad crítica que detecte riesgos antes de cualquier procesamiento del LLM. Debe actuar con latencia mínima (bypass).

## Tasks
- [ ] Crear el módulo `Alethea.Alerts.CrisisMonitor` con una lista de palabras clave y patrones de riesgo.
- [ ] Modificar el pipeline de entrada para ejecutar el `CrisisMonitor` **antes** de llamar a la IA conversacional.
- [ ] Implementar el "Cortocircuito": si se detecta crisis, responder inmediatamente con el mensaje de soporte humano predefinido (latencia de milisegundos).
- [ ] Marcar al paciente en la DB con una alerta de `urgent_intervention`.
- [ ] Disparar una notificación asíncrona (ej: PubSub para el dashboard) al detectar la crisis.
