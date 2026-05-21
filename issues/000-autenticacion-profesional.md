# Issue 000: Autenticación del Profesional

**Type**: AFK
**Blocked by**: None
**User Stories Covered**: (Prerequisito transversal — no mapea a una User Story propia)

## Description
Implementar el sistema de autenticación para el profesional (psicólogo). El schema de `Professional` ya existe con `password_hash`, pero las rutas protegidas, los plugs de sesión y la UI de login no están implementados. Esta issue es un prerequisito bloqueante para cualquier LiveView que requiera un profesional autenticado.

## Tasks
- [ ] Generar o implementar manualmente el flujo de autenticación con `phx.gen.auth` adaptado al schema `Professional` existente (email + contraseña con `pbkdf2_elixir`).
- [ ] Configurar el plug `require_authenticated_professional` para proteger todas las rutas del dashboard.
- [ ] Crear las vistas de login y logout (LiveView o controlador simple).
- [ ] Asegurar que `professional_id` queda disponible en la sesión para ser usado por las LiveViews downstream (registro de pacientes, dashboard).
- [ ] Crear test de integración que verifique que rutas protegidas redirigen a login sin sesión activa.
