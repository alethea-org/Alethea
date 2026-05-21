# Issue 005: Monitor de Crisis y Cortocircuito (Bypass)

**Type**: AFK
**Blocked by**: issues/003-integracion-meta-api-ia-reflexion.md
**User Stories Covered**: 7

## Description
Implementar una capa de seguridad crítica que detecte riesgos antes de cualquier procesamiento del LLM. Debe actuar con latencia mínima (bypass).

## Tasks
- [ ] Crear el módulo `Alethea.Alerts.CrisisMonitor` como función pura sin efectos secundarios: `detect/1` recibe texto y devuelve `:safe | {:crisis, level, triggers}`. Los patrones de riesgo deben definirse en `Application.get_env/2` (config), no hardcodeados.
- [ ] Modificar el pipeline de entrada para ejecutar el `CrisisMonitor` **antes** de llamar a la IA conversacional.
- [ ] Implementar el "Cortocircuito": si se detecta crisis, responder inmediatamente con el mensaje de soporte humano predefinido (latencia de milisegundos) sin llamar al LLM.
- [ ] Marcar al paciente en la DB con `urgent_intervention: true` al detectar la crisis. (El campo `urgent_intervention` se crea en la migración de Issue 001.)
- [ ] Disparar una notificación asíncrona vía `Phoenix.PubSub` al topic `"crisis:alerts"` para que el dashboard se actualice en tiempo real sin polling.
- [ ] Crear tests de regresión unitarios sobre `CrisisMonitor.detect/1` que verifiquen que palabras clave de riesgo siempre disparan el protocolo (sin DB, sin Oban, sin efectos secundarios).
