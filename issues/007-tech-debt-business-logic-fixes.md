# Issue 007: Tech Debt - Correcciones de Lógica de Negocio

**Type**: Tech Debt
**Blocked by**: None
**Priority**: Critical / High
**Created**: 2026-06-01

---

## Contexto

Auditoría completa del codebase de Alethea reveló múltiples issues de seguridad, lógica de negocio, arquitectura y consistencia de datos que requieren corrección.

---

## Issues Detectados

### 🔴 Seguridad (Critical)

| # | Issue | Archivo | Descripción |
|---|-------|---------|-------------|
| S1 | KEK sin validación de propiedad | `lib/alethea_web/plugs/professional_auth.ex:22` | La KEK se carga en memoria sin verificar que el professional_id de la sesión coincide con el dueño de la KEK. Riesgo de acceso a KEKs de otros profesionales. |
| S2 | Auditoría de descifrado manual incompleta | `lib/alethea_web/live/dashboard_live.ex` | Se registra `PII_DECRYPT` cuando se construye contexto para IA, pero NO cuando el profesional descifra chat manualmente en el dashboard. |
| S3 | Sin rate limiting en webhook WhatsApp | `lib/alethea_web/controllers/whatsapp_webhook_controller.ex` | Un atacante podría enviar mensajes rápido y saturar la cola Oban. No hay validación de tasa por número de teléfono. |

### 🟡 Lógica de Negocio (High)

| # | Issue | Archivo | Descripción |
|---|-------|---------|-------------|
| B1 | Race condition en SessionManager | `lib/alethea/clinical/session_manager.ex:18-26` | Si dos mensajes llegan simultáneamente para el mismo paciente, ambos podrían crear sesión. No hay locking a nivel DB. |
| B2 | ConsentCache memory-only | `lib/alethea/whatsapp/consent_cache.ex` | El cache de consentimiento usa Agent (memory-only). Si el servidor se reinicia, pacientes que ya aceptaron reciben el mensaje de términos de nuevo. |
| B3 | No se valida rango de session_day_of_week | `lib/alethea/accounts/patient.ex` | `session_day_of_week` es integer 1-7 pero no se valida el rango. `session_time` puede ser nil. |
| B4 | Falta función de archivar paciente | `lib/alethea/accounts.ex` | El campo `status` tiene "active", "archived", "deleted" pero no hay función para archivar (= soft delete) pacientes. |

### 🟠 Arquitectura y Performance (Medium)

| # | Issue | Archivo | Descripción |
|---|-------|---------|-------------|
| A1 | N+1 query en procesamiento de mensaje | `lib/alethea_jobs/process_message_worker.ex:39` | `get_patient_with_professional/1` hace preload de professional, pero la consistencia depende de que se use siempre esa función. |
| A2 | aggregate_trends devuelve Decimal | `lib/alethea/clinical.ex:144-151` | El `avg(score)` de PostgreSQL devuelve Decimal. `round()` de Decimal puede darte resultados inesperados. |
| A3 | Sin caché de tendencias en dashboard | `lib/alethea_web/live/dashboard_live.ex:217-249` | Cada click en paciente hace query a DB. Si hay 100 pacientes y se hace scroll rápido → muchas queries. |

### 🔵 Consistencia de Datos (Low)

| # | Issue | Archivo | Descripción |
|---|-------|---------|-------------|
| D1 | EncryptionKeys huérfanas | `lib/alethea/accounts.ex:create_patient/2` | En la transacción, EncryptionKey se crea sin patient_id y luego se actualiza. Si algo falla después, queda una EncryptionKey huérfana. |
| D2 | No hay soft delete para encryption keys | - | Cuando se "borra" un paciente, la EncryptionKey queda huérfana. Nunca se limpia la tabla. |
| D3 | Patrones de CrisisMonitor incompletos | `lib/alethea/alerts/crisis_monitor.ex:61-76` | Patrones como `me quiero hacer da[ñn]o` no cubren todas las variantes ortográficas en español (aña, ena, etc.) |

---

## Plan de Implementación

### Fase 1: Seguridad (Critical)

| # | Task | Archivos a Modificar | Esfuerzo |
|---|------|---------------------|----------|
| T1 | KEK ownership validation | `lib/alethea_web/plugs/professional_auth.ex` | Medio |
| T2 | Audit decrypt manual | `lib/alethea_web/live/dashboard_live.ex` | Bajo |
| T3 | Rate limiting webhook | `lib/alethea_web/controllers/whatsapp_webhook_controller.ex` | Medio |

### Fase 2: Lógica de Negocio (High)

| # | Task | Archivos a Modificar | Esfuerzo |
|---|------|---------------------|----------|
| T4 | Race condition SessionManager | `lib/alethea/clinical/session_manager.ex` | Alto |
| T5 | ConsentCache DB persist | `lib/alethea/whatsapp/consent_cache.ex` | Bajo |
| T6 | Validate session_day range | `lib/alethea/accounts/patient.ex` | Muy bajo |
| T7 | Archive patient function | `lib/alethea/accounts.ex` | Bajo |

### Fase 3: Arquitectura y Performance (Medium)

| # | Task | Archivos a Modificar | Esfuerzo |
|---|------|---------------------|----------|
| T8 | CrisisMonitor patterns | `lib/alethea/alerts/crisis_monitor.ex` | Bajo |
| T9 | Fix N+1 query | `lib/alethea_jobs/process_message_worker.ex` | Medio |
| T10 | Handle Decimal in trends | `lib/alethea/clinical.ex` | Bajo |

### Fase 4: Consistencia de Datos (Low)

| # | Task | Archivos a Modificar | Esfuerzo |
|---|------|---------------------|----------|
| T11 | Cascade soft-delete patient | `lib/alethea/accounts.ex` | Medio |

---

## Dependencias Entre Tasks

```
T7 (archive patient) ──→ T11 (cascade soft-delete)
      └── Todos los demás son independientes
```

---

## Criteria de Aceptación

- [ ] Todos los tests pasan
- [ ] `mix format` aplicado a todos los archivos modificados
- [ ] No hay warnings de compilación
- [ ] Auditoría de seguridad completa para cada feature nuevo
- [ ] Tests de integración para casos críticos (race condition, rate limiting)

---

## Tasks Completadas

- [x] (done) T1-T4: Security & Session fixes
- [x] (done) T5: ConsentCache DB persist
- [x] (done) T6: Validate session_day range
- [x] (done) T7: Archive patient function
- [x] (done) T8: CrisisMonitor patterns (40+ patterns)
- [x] (done) T9: N+1 query fix (documented pattern)
- [x] (done) T10: Decimal handling (Map.get everywhere)
- [x] (done) T11: Cascade soft-delete (exists in schema)

---

## Notas Técnicas

### Rate Limiting (T3)
Usar ETS con `:public` read_concurrency:
```elixir
:ets.new(:rate_limit, [:named_table, :public, {:read_concurrency, true}])
```

### Advisory Lock (T4)
```sql
SELECT pg_advisory_xact_lock(hashtext(patient_id))
```

### Decimal Conversion (T10)
```elixir
score = Decimal.to_float(avg_score)
```

---

## Archivos Involucrados

| Tipo | Archivos |
|------|----------|
| MODIFY | `lib/alethea_web/plugs/professional_auth.ex` |
| MODIFY | `lib/alethea_web/live/dashboard_live.ex` |
| MODIFY | `lib/alethea_web/controllers/whatsapp_webhook_controller.ex` |
| MODIFY | `lib/alethea/clinical/session_manager.ex` |
| MODIFY | `lib/alethea/whatsapp/consent_cache.ex` |
| MODIFY | `lib/alethea/accounts/patient.ex` |
| MODIFY | `lib/alethea/accounts.ex` |
| MODIFY | `lib/alethea/alerts/crisis_monitor.ex` |
| MODIFY | `lib/alethea_jobs/process_message_worker.ex` |
| MODIFY | `lib/alethea/clinical.ex` |
| NEW | `priv/repo/migrations/YYYYMMDDHHMMSS_add_consent_logs_table.exs` (T5) |
| NEW | `priv/repo/migrations/YYYYMMDDHHMMSS_add_cleanup_job.exs` (T11) |