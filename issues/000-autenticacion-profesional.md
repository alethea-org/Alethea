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

- [x] Agregar `get_professional_by_email/1` y `authenticate_professional/2` a `Alethea.Accounts` (con protección anti-timing attack vía `Pbkdf2.no_user_verify/0`)
- [x] Crear `lib/alethea_web/auth.ex` (Implementado como `AletheaWeb.Plugs.ProfessionalAuth`)
- [x] Actualizar `router.ex`:
  - Añadir `fetch_current_professional` al pipeline `:browser`
  - Scope público: `live "/login"`, `live "/register"`
  - Scope público: `delete "/logout", SessionController, :delete`
  - Scope autenticado: `live "/dashboard", DashboardLive, :index`
- [x] Crear `lib/alethea_web/controllers/session_controller.ex`
- [x] Crear `lib/alethea_web/live/professional_auth_live.ex` (Implementado como `LoginLive` y `ProfessionalRegistrationLive`)
- [x] Crear `lib/alethea_web/live/dashboard_live.ex`
- [x] Crear `test/alethea_web/auth_test.exs`
- [x] Ejecutar `mix test` y verificar que todo pase.

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
