# Issue 000: Autenticación del Profesional

**Type**: AFK
**Blocked by**: None
**User Stories Covered**: (Prerequisito transversal — no mapea a una User Story propia)

## Paralelización y Desacoplamiento (Contract-Driven Development)

> [!NOTE]
> Aunque esta issue es la base de la autenticación real, **no bloquea el desarrollo de las issues 001 (Bóveda) y 006 (Dashboard)**. Para permitir el trabajo en paralelo, se define un contrato y un bypass de desarrollo `AletheaWeb.AuthMock` en la Issue 001 que simula la sesión activa y la KEK en memoria del socket. Al finalizar esta issue, se sustituirá el mock en el router por el módulo real `AletheaWeb.Auth`.

## Description

Implementar el sistema de autenticación para el profesional (psicólogo). El schema de `Professional` ya existe con `password_hash` (usando `Pbkdf2`), `mfa_secret`, `email` y `full_name`. Las rutas protegidas, los plugs de sesión y la UI de login no están implementados. Esta issue es un prerequisito bloqueante para cualquier LiveView que requiera un profesional autenticado.

## Decisiones de Diseño

| Decisión | Elección | Justificación |
|---|---|---|
| Estrategia de implementación | Manual (sin `phx.gen.auth`) | El schema `Professional` ya existe; correr el generator generaría conflictos |
| Gestión de sesión | Session-based (cookie `Plug.Session`) | Sin tabla de tokens — suficiente para un uso de un solo profesional por dispositivo |
| UI de login | LiveView en `/login` | Consistente con el resto de la app; permite validación en tiempo real |
| MFA | **Diferido** a issue separada | El campo `mfa_secret` ya existe en el schema, pero el flujo TOTP es scope propio |
| Protección de rutas | Módulo `AletheaWeb.Auth` con un Plug + hook `on_mount` | Un solo lugar para toda la lógica de autenticación |
| Paths | `GET /login` (LiveView), `POST /login` y `DELETE /logout` (Controller) | El `POST /login` es estrictamente necesario para que un endpoint HTTP tradicional pueda escribir la cookie HttpOnly de sesión (LiveView no puede) |
| Redirect post-login | `/dashboard` | Raíz de todas las LiveViews autenticadas downstream |

## Tasks

- [ ] Agregar `get_professional_by_email/1` y `authenticate_professional/2` a `Alethea.Accounts` (con protección anti-timing attack vía `Pbkdf2.no_user_verify/0`)
- [ ] Crear `lib/alethea_web/auth.ex` con:
  - Plug `fetch_current_professional/2` — lee `professional_id` de sesión y asigna `@current_professional` al conn
  - Plug `require_authenticated_professional/2` — redirige a `/login` si no hay sesión
  - Hook `on_mount :fetch_current_professional` — equivalente LiveView del fetch plug (para rutas públicas como el login)
  - Hook `on_mount :require_authenticated_professional` — equivalente LiveView del require plug (para `live_session` protegidas)
  - Helpers `log_in_professional/2` y `log_out_professional/1` que renuevan la sesión CSRF
- [ ] Actualizar `router.ex`:
  - Añadir `fetch_current_professional` al pipeline `:browser`
  - Scope público: `live "/login", ProfessionalAuthLive, :new` en `live_session :unauthenticated`
  - Scope público: `delete "/logout", SessionController, :delete`
  - Scope autenticado: `live "/dashboard", DashboardLive, :index` en `live_session :require_authenticated_professional`
- [ ] Crear `lib/alethea_web/controllers/session_controller.ex` con:
  - `create/2`: maneja el `POST /login`, verifica la contraseña con `Accounts.authenticate_professional/2`, setea la cookie con `log_in_professional/2` y redirige a `/dashboard`
  - `delete/2`: maneja el `DELETE /logout` para limpiar la sesión
- [ ] Crear `lib/alethea_web/live/professional_auth_live.ex` — LiveView de login con formulario (`action="/login" method="post"`). Usa `phx-submit` para validación de formato, pero el submit exitoso hace un POST HTML estándar hacia `SessionController`
- [ ] Crear `lib/alethea_web/live/dashboard_live.ex` — LiveView placeholder protegida, muestra bienvenida con `@current_professional.full_name`; desbloquea todas las features downstream
- [ ] Crear `test/alethea_web/auth_test.exs` con 3 tests de integración:
  1. `GET /dashboard` sin sesión → redirige a `/login`
  2. Login con credenciales válidas → sesión activa y redirect a `/dashboard`
  3. Login con contraseña incorrecta → flash de error en la página de login
- [ ] Ejecutar `mix precommit` y corregir cualquier issue pendiente

## Archivos Involucrados

| Acción | Archivo |
|---|---|
| MODIFY | `lib/alethea/accounts.ex` |
| NEW | `lib/alethea_web/auth.ex` |
| MODIFY | `lib/alethea_web/router.ex` |
| NEW | `lib/alethea_web/controllers/session_controller.ex` |
| NEW | `lib/alethea_web/live/professional_auth_live.ex` |
| NEW | `lib/alethea_web/live/dashboard_live.ex` |
| NEW | `test/alethea_web/auth_test.exs` |

## Notas

- **MFA diferido**: El campo `mfa_secret` en `Professional` ya existe. La issue de MFA debe crearse como issue separada y marcarse como bloqueada por esta.
- **Sin migración**: Implementación session-based, no requiere tabla `professional_tokens`.
- **Anti-timing attack**: `authenticate_professional/2` siempre debe llamar `Pbkdf2.no_user_verify/0` cuando el email no existe, para evitar enumeración de usuarios por diferencia de tiempo de respuesta.
