# Issue 001: Registro de Pacientes y Bóveda Segura

**Type**: AFK
**Blocked by**: 000
**User Stories Covered**: PR1, S1, S2, S3

## 🤝 Contrato de Paralelización (Contract-Driven Development)

Para permitir el desarrollo de esta issue de forma paralela y síncrona con la Issue 000 (Autenticación del Profesional), se define un bypass de autenticación para desarrollo en local.

### Contrato: `AletheaWeb.AuthMock`
El desarrollador creará de inmediato en `lib/alethea_web/auth_mock.ex` un módulo dummy que cumpla con los asignados esperados de LiveView:
```elixir
defmodule AletheaWeb.AuthMock do
  import Phoenix.Component
  import Phoenix.LiveView

  def on_mount(:require_authenticated_professional, _params, _session, socket) do
    mock_prof = %Alethea.Accounts.Professional{
      id: "00000000-0000-0000-0000-000000000000",
      full_name: "Dra. Constanza (Mock)",
      email: "constanza@alethea.com"
    }

    # KEK mock determinista de 32 bytes para desarrollo local.
    mock_kek =
      :crypto.hash(
        :sha256,
        "alethea-dev-auth-mock-kek:" <> mock_prof.id
      )

    {:cont,
     socket
     |> assign(:current_professional, mock_prof)
     |> assign(:professional_kek, mock_kek)}
  end
end
```
En `router.ex`, bajo el pipeline y scopes de LiveView, se utilizará temporalmente `AletheaWeb.AuthMock` en vez de `AletheaWeb.Auth` para montar la live session.
Esto habilita la visualización y pruebas de la UI de registro de pacientes en el navegador de manera inmediata. Una vez completada la Issue 000, simplemente se cambiará `AuthMock` por `Auth` en `router.ex`.

## Description

Implementar la interfaz completa para que el psicólogo registre pacientes y asegurar el esquema de seguridad mandatorio. El canal de comunicación es **Telegram Bot**, no WhatsApp. El paciente se autentica con un código de 6 dígitos entregado por el profesional.

## Decisiones de Diseño

| Decisión | Elección | Justificación |
|---|---|---|
| Canal | Telegram Bot | Gratis, sin costo por mensaje |
| Auth paciente | Código de 6 dígitos | Simple, el profesional entrega el código presencialmente o por chat privado |
| Migraciones | Una sola migración nueva que agrupa todos los cambios de schema | Simplifica el historial; los cambios son interdependientes |
| Generación de DEK | `32` bytes aleatorios con `:crypto.strong_rand_bytes(32)` | Estándar NIST para AES-256; entropía máxima |
| KEK por profesional | KEK aleatoria de 32 bytes generada al crear el profesional, **almacenada cifrada** en `encryption_keys` (type: `'professional'`) protegida por el `Vault` global | Evita la pérdida de datos al cambiar la contraseña del profesional; permite rotación de KEK si es necesario |
| Lifecycle de la KEK | La KEK se descifra del Vault al hacer login, se retiene en memoria (assign del LiveView) y se pasa a `create_patient/2` | No requiere re-descifrado en cada operación; se libera al cerrar sesión |
| Cifrado del teléfono | `Alethea.Encryption.PatientVault.encrypt_for_patient/2` usando `:crypto.crypto_one_time_aead/6` (AES-256-GCM), IV aleatorio prefijado al ciphertext | Permite cifrado con DEKs arbitrarias sin atar el Vault global |
| Hash para búsqueda | HMAC-SHA256 con un **secreto global del sistema** (`Application.fetch_env!(:alethea, :phone_hash_secret)`) como clave y el número como mensaje | Permite lookup O(1) desde el webhook (que no tiene la KEK en memoria) y garantiza unicidad global |
| Transacción DB | `Ecto.Multi` | Rollback atómico de todos los pasos: DEK, registro de llave, cifrado, inserción de paciente |
| UI de registro | `PatientLive.Index` con modal in-place | Sin navegación extra; coherente con el patrón de la app |
| Campos del formulario | `alias` + `teléfono` (formato E.164) | Mínimo necesario al crear; `urgent_intervention` se gestiona después |
| Código de verificación | 6 dígitos aleatorios, expires en 15 minutos | Entregado por el profesional, el paciente lo ingresa al bot de Telegram |
| Telegram auth state | `Accounts.create_patient_auth_code/2` genera código; `Accounts.verify_patient_auth_code/2` valida | El paciente existe cuando verifica el código exitosamente |
| Tests de integración | Tests covering ilegibilidad, borrado criptográfico y constraint de unicidad | Cubre ilegibilidad, borrado criptográfico y constraint de unicidad |

## Arquitectura de Cifrado

```
Vault global (AES-256-GCM, key del config)
  └── KEK del profesional (almacenada cifrada en encryption_keys type:'professional')
        └── DEK del paciente (almacenada cifrada en encryption_keys type:'patient')
              ├── encrypted_phone (AES-256-GCM via PatientVault)
              └── phone_hash (HMAC-SHA256, clave = phone_hash_secret)
```

**Borrado Criptográfico**: destruir/nilificar el registro de DEK en `encryption_keys` hace irrecuperables todos los datos del paciente sin afectar a otros. Destruir la KEK del profesional hace irrecuperables los datos de *todos* sus pacientes.

## Flujo de Registro del Paciente

```
Profesional crea paciente → genera código de 6 dígitos → paciente recibe link al bot → paciente escribe /start → ingresa código → autenticado
```

## Tasks

### Migración
- [ ] Generar migración si es necesaria

### Dominio — Telegram Auth
- [ ] Crear schema `PatientAuthCode` (código, expires_at, patient_id)
- [ ] Crear `Accounts.create_patient_auth_code/2`
- [ ] Crear `Accounts.verify_patient_auth_code/2`

### Dominio — Telegram Gateway
- [ ] Crear `Alethea.TelegramBot` (recibe updates de Telegram)
- [ ] Implementar flujo /start → pedir código → verificar → guardar Telegram chat_id

### Dominio — Cifrado por Paciente
- [ ] Crear `lib/alethea/encryption/patient_vault.ex`
- [ ] Crear `lib/alethea/encryption/professional_kek.ex`
- [ ] Crear `lib/alethea/accounts.ex` (Añadir `create_patient/2` con Envelope Encryption)

### Dominio — Contexto `Alethea.Accounts`
- [ ] Añadir `load_professional_kek(professional)`
- [ ] Reemplazar `create_patient/1` por `create_patient(attrs, kek_bytes)` con E.164 normalization y Ecto.Multi.

### Configuración — Entornos y `config/runtime.exs`
- [ ] Configurar `:phone_hash_secret` en todos los entornos.
- [ ] Configurar `:telegram_bot_token` en todos los entornos.

### Web — LiveView
- [ ] Crear `lib/alethea_web/live/patient_live/index.ex` (UI + Empty State)
- [ ] Añadir ruta en `router.ex`
- [ ] Actualizar el flujo de login para asignar KEK al socket.

### Tests
- [ ] Tests de ilegibilidad SQL
- [ ] Tests de borrado criptográfico
- [ ] Tests de unicidad global
- [ ] Tests de verificación de código

## Archivos Involucrados

| Acción | Archivo |
|---|---|
| NEW | `lib/alethea/accounts/patient_auth_code.ex` |
| MODIFY | `lib/alethea/accounts.ex` |
| NEW | `lib/alethea/telegram_bot.ex` |
| NEW | `lib/alethea/encryption/patient_vault.ex` |
| NEW | `lib/alethea/encryption/professional_kek.ex` |
| MODIFY | `lib/alethea/accounts/patient.ex` |
| MODIFY | `lib/alethea/accounts/encryption_key.ex` |
| NEW | `lib/alethea_web/live/patient_live/index.ex` |
| MODIFY | `lib/alethea_web/router.ex` |
| MODIFY | `lib/alethea_web/live/professional_auth_live.ex` |

## Notas

- **KEK en assigns**: la KEK en bytes **nunca se serializa** a la sesión del browser. Vive solo en el proceso LiveView como `socket.assigns.professional_kek`. Al hacer logout o si el proceso muere, se libera de memoria automáticamente.
- **Formato E.164**: el número de teléfono debe normalizarse a E.164 antes de cifrar/hashear para garantizar unicidad del hash.
- **`urgent_intervention`**: campo de base para la feature de alertas clínicas.
