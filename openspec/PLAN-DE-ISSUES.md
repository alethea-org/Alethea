# Alethea - Plan de Issues para el Equipo

**Proyecto**: Alethea - Asistente Clínico con IA  
**Fecha**: 2026-06-03  
**Base**: SDD Proposals (openspec/changes/)  
**Estado**: Listo para distribución al equipo

---

## Resumen Ejecutivo

Se identificaron **4 áreas de trabajo** con **20+ issues concretos**:

| Área | Issues | Complejidad Promedio | Prioridad |
|------|--------|---------------------|-----------|
| **Features Nuevos** | 5 | 2.4/5 | Alta |
| **Refinamientos** | 5 | 2.6/5 | Media |
| **DevOps/Deployment** | 5 | 2.4/5 | Media |
| **Testing/Integración** | 5 | 2.6/5 | Alta |

---

## 🎯 Features Nuevos (sdd-features-001)

### FEAT-001: Emotion Trend Chart
**Complejidad**: 2/5 | **Asignado a**: frontend  
**Descripción**: Agregar visualización de tendencias emocionales de 7 días al detalle del paciente  
**Entregable**: Componente SVG con gráfico de barras, leyenda de colores  
**Archivos**: `lib/alethea_web/live/dashboard_live/components/emotion_chart.ex`  
**Criterios de aceptación**:
- [ ] Renderiza en <500ms para hasta 500 registros
- [ ] Ventana de 7 días configurable por URL param
- [ ] Estado vacío cuando no hay datos

---

### FEAT-002: In-App Notification Center
**Complejidad**: 3/5 | **Asignado a**: frontend + backend  
**Descripción**: Centro de notificaciones en tiempo real vía Phoenix.PubSub  
**Entregable**: LiveView component con historial, severidad, mark-as-read  
**Archivos**: `lib/alethea_web/live/dashboard_live/components/notification_center.ex`  
**Criterios de aceptación**:
- [ ] Crisis alerts aparecen en <2 segundos
- [ ] Persiste en base de datos
- [ ] Max 100 notificaciones con paginación

---

### FEAT-003: Advanced Patient Search
**Complejidad**: 2/5 | **Asignado a**: frontend  
**Descripción**: Búsqueda en vivo con debounce, filtros por estado, ordenamiento  
**Entregable**: Componente de búsqueda con filter chips y sort options  
**Archivos**: `lib/alethea_web/live/dashboard_live/components/patient_search.ex`  
**Criterios de aceptación**:
- [ ] Resultados en <300ms (debounced)
- [ ] Filtros combinan con AND
- [ ] No XSS en alias de paciente

---

### FEAT-004: Structured Weekly Report
**Complejidad**: 3/5 | **Asignado a**: backend  
**Descripción**: Extender schema Summary con campos estructurados (anxiety_score, social_score, etc.)  
**Entregable**: Campos nuevos en tabla summaries, output JSON estructurado  
**Archivos**: 
- `priv/repo/migrations/`
- `lib/alethea/reports/summary.ex`
- `lib/alethea/reports/weekly_summary_chain.ex`
**Criterios de aceptación**:
- [ ] Campos nulos para reportes existentes
- [ ] JSON output matchea schema
- [ ] Tests cubren todos los campos nuevos

---

### FEAT-005: Session Reminder WhatsApp Messages
**Complejidad**: 2/5 | **Asignado a**: backend  
**Descripción**: Oban worker que envía recordatorios 24h antes de sesiones  
**Entregable**: `SessionReminderWorker` con retry y logging  
**Archivos**: `lib/alethea_jobs/session_reminder_worker.ex`  
**Criterios de aceptación**:
- [ ] Ejecuta dentro de 1 minuto del horario
- [ ] Retry hasta 3 veces con exponential backoff
- [ ] Logs de éxito/fallo

---

## 🔧 Refinamientos (sdd-refinements-001)

### REF-001: Password Reset Flow
**Complejidad**: 3/5 | **Asignado a**: backend  
**Descripción**: Flow completo de reset de contraseña vía email  
**Entregable**: Formulario "forgot password", token seguro (1h expiry), email delivery  
**Archivos**:
- `lib/alethea/accounts/professional.ex`
- `lib/alethea/accounts.ex`
- `lib/alethea_web/controllers/registration_controller.ex`
- `lib/alethea_web/router.ex`
**Criterios de aceptación**:
- [ ] Email enviado en <30 segundos
- [ ] Token expira después de 1 hora
- [ ] Rate limit: 3 requests/hora/email

---

### REF-002: Remember Me Cookie
**Complejidad**: 2/5 | **Asignado a**: backend + frontend  
**Descripción**: Sesión persistente con cookie segura de 30 días  
**Entregable**: Token rotativo en cookie HttpOnly, Secure  
**Archivos**:
- `lib/alethea_web/controllers/session_controller.ex`
- `lib/alethea_web/plugs/professional_auth.ex`
**Criterios de aceptación**:
- [ ] Cookie persiste reinicio de navegador
- [ ] Token rotado en cada uso
- [ ] Logout limpia cookie

---

### REF-003: Batch RoBERTa Processing
**Complejidad**: 2/5 | **Asignado a**: backend  
**Descripción**: Worker diario que procesa mensajes sin análisis emocional  
**Entregable**: `ScheduledEmotionAnalysisWorker`, usa `analyze_batch/1` existente  
**Archivos**: `lib/alethea_jobs/scheduled_emotion_analysis_worker.ex`  
**Criterios de aceptación**:
- [ ] Ejecuta diario a las 02:00 UTC
- [ ] Procesa hasta 1000 mensajes por corrida
- [ ] Idempotente

---

### REF-004: Session Recovery Logic
**Complejidad**: 3/5 | **Asignado a**: backend + frontend  
**Descripción**: Merge de sesiones fragmentadas dentro de ventana de 2 horas  
**Entregable**: Campo `merged_from_session_id`, lógica de merge en SessionManager  
**Archivos**:
- `lib/alethea/clinical/session.ex`
- `lib/alethea/clinical/session_manager.ex`
- `lib/alethea/clinical/session_timeout_worker.ex`
**Criterios de aceptación**:
- [ ] Merge correcto dentro de ventana de 2h
- [ ] Sin sesiones duplicadas
- [ ] UI muestra indicador de merge

---

### REF-005: Response Diversity for AI
**Complejidad**: 3/5 | **Asignado a**: backend  
**Descripción**: Evitar respuestas repetitivas con temperature y response cache  
**Entregable**: `ResponseCache` con TTL 5min, parámetros configurables  
**Archivos**:
- `lib/alethea/ai/response_cache.ex`
- `lib/alethea/ai/phi_worker.ex`
- `lib/alethea/ai/guided_conversation_chain.ex`
**Criterios de aceptación**:
- [ ] Cache hit rate > 30%
- [ ] Crisis messages nunca cacheadas
- [ ] Sin memory leak en 24h

---

## 🚀 DevOps / Deployment (sdd-devops-001)

### DEV-001: Telemetry & Observability
**Complejidad**: 2/5 | **Asignado a**: DevOps  
**Descripción**: Agregar métricas de negocio al dashboard de Oban  
**Entregable**: Métricas de jobs procesados, errores, latency por worker  
**Archivos**: `lib/alethea/application.ex`, config de Oban  
**Criterios de aceptación**:
- [ ] Métricas visible en Oban dashboard
- [ ] Alertas configuradas para error rate > 5%

---

### DEV-002: Health Checks
**Complejidad**: 2/5 | **Asignado a**: DevOps  
**Descripción**: Endpoints `/health`, `/health/ready` para Kubernetes  
**Entregable**: Plugs de health check con DB y Redis check  
**Archivos**: `lib/alethea_web/endpoint.ex` o router  
**Criterios de aceptación**:
- [ ] `/health` responde 200 si app corriendo
- [ ] `/health/ready` verifica DB + Redis

---

### DEV-003: Docker Configuration
**Complejidad**: 3/5 | **Asignado a**: DevOps  
**Descripción**: Dockerfile optimizado multi-stage + docker-compose  
**Entregable**: `.dockerignore`, Dockerfile, docker-compose.yml  
**Archivos**: raíz del proyecto  
**Criterios de aceptación**:
- [ ] Build < 5 minutos
- [ ] Imagen < 500MB
- [ ] Compose levanta todo con `docker-compose up`

---

### DEV-004: Oban Dashboard
**Complejidad**: 2/5 | **Asignado a**: DevOps  
**Descripción**: Proteger y exponer dashboard de Oban para admins  
**Entregable**: Route protegida, autenticación profesional  
**Archivos**: `lib/alethea_web/router.ex`  
**Criterios de aceptación**:
- [ ] Solo profesionales autenticados acceden
- [ ] Jobs visibles con estado actual

---

### DEV-005: Database Monitoring
**Complejidad**: 2/5 | **Asignado a**: DevOps  
**Descripción**: Query stats, connection pool monitoring  
**Entregable**: Logs de slow queries, métricas de pool  
**Archivos**: `config/runtime.exs`  
**Criterios de aceptación**:
- [ ] Queries > 1s loggeadas como warning
- [ ] Pool saturation visible en métricas

---

## 🧪 Testing / Integración (sdd-integration-001)

### TEST-001: WhatsApp Webhook Contracts
**Complejidad**: 3/5 | **Asignado a**: QA  
**Descripción**: Test fixtures con payloads reales de WhatsApp API  
**Entregable**: Fixtures en `test/fixtures/whatsapp/`  
**Archivos**: `test/alethea/whatsapp/`  
**Criterios de aceptación**:
- [ ] Todos los message types tienen fixture
- [ ] Tests de signature verification

---

### TEST-002: E2E Tests with Wallaby
**Complejidad**: 3/5 | **Asignado a**: QA  
**Descripción**: Tests end-to-end del flow profesional → paciente  
**Entregable**: Tests de login, dashboard, paciente  
**Archivos**: `test/alethea_web/e2e/`  
**Criterios de aceptación**:
- [ ] Login flow completo
- [ ] Creación de paciente
- [ ] Envío de mensaje de prueba

---

### TEST-003: AI Worker Mocks
**Complejidad**: 2/5 | **Asignado a**: QA  
**Descripción**: Mocks hermosos para RoBERTa y PhiWorker en tests  
**Entregable**: GenServer de mock con respuestas configurables  
**Archivos**: `test/support/mocks/ai_mock.ex`  
**Criterios de aceptación**:
- [ ] Mock controllable desde tests
- [ ] Soporta respuestas de error también

---

### TEST-004: Oban Test Utilities
**Complejidad**: 2/5 | **Asignado a**: QA  
**Descripción**: Helpers para testing de workers asincrónicos  
**Entregable**: `ObanTestHelper` con assert for job completion  
**Archivos**: `test/support/oban_helper.ex`  
**Criterios de aceptación**:
- [ ] `assert_job_completed(worker, args)`
- [ ] Helper para hacer drain jobs en tests

---

### TEST-005: OpenAPI Documentation
**Complejidad**: 3/5 | **Asignado a**: backend  
**Descripción**: Generar y mantener docs de API para integraciones  
**Entregable**: Swagger UI, archivo openapi.json  
**Archivos**: `priv/static/api-docs/`  
**Criterios de aceptación**:
- [ ] Webhook endpoint documentado
- [ ] Auth flows documentados

---

## 📋 Cómo Usar Este Plan

### Para crear issues en GitHub:
1. Copiar el código (ej: `FEAT-001`)
2. Usar el template de issue del repo
3. Asignar a un compañero
4. Linkear al SDD proposal correspondiente

### Para empezar a trabajar:
1. Hacer checkout de `main`
2. Crear branch: `git checkout -b feat/FEAT-001-emotion-chart`
3. Leer el proposal completo en `openspec/changes/sdd-features-001-proposal.md`
4. Implementar siguiendo los criterios de aceptación
5. Tests primero (TDD)

### Orden sugerido:
1. **FEAT-003** (búsqueda, simple) → buen warm-up
2. **FEAT-001** (gráfico, frontend)
3. **TEST-002** (E2E, mejora confianza)
4. **REF-003** (batch RoBERTa, backend)
5. **DEV-003** (Docker, DevOps)

---

## 📎 Archivos de Referencia

- Propuestas SDD: `openspec/changes/`
  - `sdd-features-001-proposal.md`
  - `sdd-refinements-001-proposal.md`
  - `sdd-devops-001-proposal.md`
  - `sdd-integration-001-proposal.md`
- Configuración: `openspec/config.yaml`
- Template: `openspec/templates/change-template.md`