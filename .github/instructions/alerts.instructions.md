---
applyTo: "lib/alethea/alerts/**"
---

# Instrucciones: Módulo Alerts (Monitor de Crisis)

Estas instrucciones aplican a todos los archivos dentro de `lib/alethea/alerts/`.

## Regla de Orden de Ejecución (CRÍTICA)

El `CrisisMonitor` DEBE ejecutarse SIEMPRE **antes** que cualquier llamada al LLM.
El orden del pipeline es innegociable:

```
Mensaje entrante → CrisisMonitor.check/2 → (si OK) → Sanitizer → LLM
```

**NUNCA** inviertas este orden. El cortocircuito debe tener latencia de milisegundos.

## Cortocircuito (Circuit Breaker)

- Si `CrisisMonitor.check/2` retorna `{:crisis, message}`, enviar `message` inmediatamente.
- No esperes respuesta del LLM. No pases el contenido al sanitizador.
- El envío de la respuesta de protocolo es **sincrónico** (baja latencia).
- La notificación al psicólogo es **asíncrona** (Oban worker).

## Patrones de Detección

- Los patrones de riesgo son `Regex` compilados, cargados desde config.
- **NUNCA** hardcodees patrones en el módulo de lógica (solo en `CrisisPatterns`).
- Los patrones deben ser case-insensitive (`~r/.../i`).
- Un test de regresión por patrón es OBLIGATORIO. Si un patrón falla, es un bug crítico.

## PubSub y Notificaciones

- Al detectar una crisis, publicar en `"psychologist:alerts"` via `Phoenix.PubSub`.
- El payload debe incluir: `patient_id`, el trigger detectado, y `DateTime.utc_now()`.
- El campo `urgent_intervention` del paciente DEBE actualizarse en la BD.

## Testing (Crítico)

Los tests del `CrisisMonitor` son los más importantes del sistema.
Cada patrón de riesgo registrado en `CrisisPatterns` DEBE tener al menos un test que
verifique que dispara el cortocircuito correctamente. Estos tests NUNCA deben fallar.
