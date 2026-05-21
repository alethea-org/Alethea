# Issue 001: Registro de Pacientes y Bóveda Segura

**Type**: AFK
**Blocked by**: None (AuthMock / Contract-Driven Development)
**User Stories Covered**: 1, 8

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
    # KEK simulada de 32 bytes para operaciones criptográficas
    mock_kek = :crypto.strong_rand_bytes(32)

    {:cont,
     socket
     |> assign(:current_professional, mock_prof)
     |> assign(:professional_kek, mock_kek)}
  end
end
```
En `router.ex`, bajo el pipeline y scopes de LiveView, se utilizará temporalmente `AletheaWeb.AuthMock` en vez de `AletheaWeb.Auth` para montar la live session:
```elixir
live_session :require_authenticated_professional,
  on_mount: [{AletheaWeb.AuthMock, :require_authenticated_professional}] do
  live "/patients", PatientLive.Index, :index
end
```
Esto habilita la visualización y pruebas de la UI de registro de pacientes en el navegador de manera inmediata. Una vez completada la Issue 000, simplemente se cambiará `AuthMock` por `Auth` en `router.ex`.

## Description

Implementar la interfaz completa para que el psicólogo registre pacientes y asegurar el esquema de seguridad mandatorio por el manual de ingeniería, alineado con la jerarquía de llaves existente (`encryption_keys`) y el modelo de Envelope Encryption definido en el DER.

## Decisiones de Diseño

| Decisión | Elección | Justificación |
|---|---|---|
| Migraciones | Una sola migración nueva que agrupa todos los cambios de schema | Simplifica el historial; los cambios son interdependientes |
| Generación de DEK | `32` bytes aleatorios con `:crypto.strong_rand_bytes(32)` | Estándar NIST para AES-256; entropía máxima |
| KEK por profesional | KEK derivada con PBKDF2 de la contraseña del profesional, **almacenada cifrada** en `encryption_keys` (type: `'professional'`) protegida por el `Vault` global | Más correcto criptográficamente que una KEK global; habilita borrado criptográfico por profesional |
| Lifecycle de la KEK | La KEK se descifra del Vault al hacer login, se retiene en memoria (assign del LiveView) y se pasa a `create_patient/2` | No requiere re-descifrado en cada operación; se libera al cerrar sesión |
| Cifrado del número de WhatsApp | `Alethea.Encryption.PatientVault.encrypt_for_patient/2` usando `:crypto.crypto_one_time_aead/6` (AES-256-GCM), IV aleatorio prefijado al ciphertext | Permite cifrado con DEKs arbitrarias sin atar el Vault global |
| Hash para búsqueda (ADR 02) | HMAC-SHA256 con un **secreto global del sistema** (`Application.get_env(:alethea, :phone_hash_secret)`) como clave y el número como mensaje | Permite lookup O(1) desde el webhook (que no tiene la KEK en memoria) y garantiza unicidad global |
| Transacción DB | `Ecto.Multi` | Rollback atómico de todos los pasos: DEK, registro de llave, cifrado, inserción de paciente |
| UI de registro | `PatientLive.Index` con modal in-place | Sin navegación extra; coherente con el patrón de la app |
| Campos del formulario | `alias` + `whatsapp_number` (formato E.164) | Mínimo necesario al crear; `urgent_intervention` se gestiona después |
| Tests de integración | 3 tests (ver sección Tasks) | Cubre ilegibilidad, borrado criptográfico y constraint de unicidad |

## Arquitectura de Cifrado

```
Vault global (AES-256-GCM, key del config)
  └── KEK del profesional (almacenada cifrada en encryption_keys type:'professional')
        └── DEK del paciente (almacenada cifrada en encryption_keys type:'patient')
              ├── encrypted_whatsapp_number (AES-256-GCM via PatientVault)
              └── whatsapp_number_hash (HMAC-SHA256, clave = DEK)
```

**Borrado Criptográfico**: destruir/nilificar el registro de DEK en `encryption_keys` hace irrecuperables todos los datos del paciente sin afectar a otros. Destruir la KEK del profesional hace irrecuperables los datos de *todos* sus pacientes.

## Tasks

### Migración
- [ ] Generar migración `add_security_fields_to_patients_and_keys` con:
  - `alter table(:encryption_keys)`: añadir `professional_id` como FK a `professionals` (nullable, `on_delete: :nilify_all`, tipo `:binary_id`) — resuelve la jerarquía de llaves para el tipo `'professional'`
  - `alter table(:patients)`: añadir `urgent_intervention` (`:boolean`, default: `false`, null: `false`)

### Dominio — Cifrado por Paciente
- [ ] Crear `lib/alethea/encryption/patient_vault.ex` con:
  - `encrypt_for_patient(plaintext, dek_bytes)` → `{:ok, ciphertext}` usando `:crypto.crypto_one_time_aead/6` (AES-256-GCM) con IV de 12 bytes aleatorios prefijados al ciphertext binario
  - `decrypt_for_patient(ciphertext, dek_bytes)` → `{:ok, plaintext}` extrayendo el IV del prefijo
- [ ] Crear `lib/alethea/encryption/professional_kek.ex` con:
  - `derive_kek(password, professional_id)` → 32 bytes usando `:crypto.pbkdf2_hmac(:sha256, password, professional_id, 100_000, 32)` — la KEK es determinista a partir de la contraseña y el ID del profesional
  - `store_kek(professional, kek_bytes)` → cifra la KEK con `Vault.encrypt!/1` y guarda en `encryption_keys` (type: `'professional'`, `professional_id` = professional.id)
  - `load_kek(professional)` → busca el registro `type: 'professional'` del profesional, descifra con `Vault.decrypt!/1` y retorna los bytes

### Dominio — Contexto `Alethea.Accounts`
- [ ] Añadir `load_professional_kek(professional)` que llama a `ProfessionalKek.load_kek/1` — usado por el LiveView de login para obtener la KEK en memoria tras autenticación
- [ ] Reemplazar `create_patient/1` por `create_patient(attrs, kek_bytes)` implementado con `Ecto.Multi`:
  1. Generar DEK: `:crypto.strong_rand_bytes(32)`
  2. Cifrar/wrap de la DEK con la KEK del profesional: `PatientVault.encrypt_for_patient(dek_bytes, kek_bytes)` (usando la KEK pasada como argumento, **no** el Vault global — ver nota abajo*)
  3. Insertar `EncryptionKey` (type: `'patient'`, patient_id aún nil)
  4. Cifrar número: `PatientVault.encrypt_for_patient(whatsapp_number, dek_bytes)`
  5. Calcular hash determinista global: `:crypto.mac(:hmac, :sha256, Application.get_env(:alethea, :phone_hash_secret), whatsapp_number)` → Base64
  6. Insertar `Patient` con `encrypted_whatsapp_number`, `whatsapp_number_hash`, `encryption_key_id`
  7. Actualizar `EncryptionKey` con el `patient_id` resultante del paso 6

> *Nota: el paso 2 requiere realizar el wrapping de la DEK del paciente usando la KEK del profesional (usando `PatientVault.encrypt_for_patient(dek_bytes, kek_bytes)` para este propósito). La KEK del profesional se almacena cifrada por el Vault global en la base de datos (segundo nivel), y la DEK cifrada del paciente se almacena en `encryption_keys.encrypted_key` (type: `'patient'`). Así, no se mezcla el cifrado global del Vault con las claves individuales de cada paciente.

### Web — LiveView
- [ ] Crear `lib/alethea_web/live/patient_live/index.ex` (`PatientLive.Index`):
  - Listado de pacientes del profesional autenticado (usando streams)
  - Modal de registro con campos `alias` y `whatsapp_number`
  - `handle_event("save_patient", params, socket)` que llama a `Accounts.create_patient(attrs, socket.assigns.professional_kek)`
  - Flash de éxito/error; cierre del modal al guardar
- [ ] Añadir ruta en `router.ex`: `live "/patients", PatientLive.Index, :index` dentro del `live_session :require_authenticated_professional`
- [ ] Actualizar el flujo de login en `ProfessionalAuthLive`/`SessionController` para llamar a `Accounts.load_professional_kek(professional)` y asignar la KEK descifrada al socket como `professional_kek` (assign en memoria, no persiste en sesión)

### Tests
- [ ] Crear `test/alethea/accounts_test.exs` con 3 tests de integración:
  1. **Ilegibilidad SQL directa**: tras `create_patient/2`, query directa a `patients` via `Repo.query!("SELECT encrypted_whatsapp_number FROM patients WHERE id = $1", [id])` confirma que el resultado es binario y distinto del número original
  2. **Borrado criptográfico**: eliminar/nilificar el registro `EncryptionKey` del paciente y verificar que `decrypt_for_patient(ciphertext, nil)` falla o que el DEK ya no puede reconstituirse
  3. **Constraint de unicidad**: registrar el mismo número de WhatsApp dos veces lanza `{:error, changeset}` con error en `whatsapp_number_hash` (unicidad global asegurada por índice único)

## Archivos Involucrados

| Acción | Archivo |
|---|---|
| NEW (migración) | `priv/repo/migrations/<ts>_add_security_fields_to_patients_and_keys.exs` |
| NEW | `lib/alethea/encryption/patient_vault.ex` |
| NEW | `lib/alethea/encryption/professional_kek.ex` |
| MODIFY | `lib/alethea/accounts.ex` |
| MODIFY | `lib/alethea/accounts/patient.ex` (changeset actualizado) |
| MODIFY | `lib/alethea/accounts/encryption_key.ex` (añadir `belongs_to :professional`) |
| NEW | `lib/alethea_web/live/patient_live/index.ex` |
| MODIFY | `lib/alethea_web/router.ex` |
| MODIFY | `lib/alethea_web/live/professional_auth_live.ex` (asignar KEK al socket) |
| NEW | `test/alethea/accounts_test.exs` |

## Notas

- **KEK en assigns**: la KEK en bytes **nunca se serializa** a la sesión del browser. Vive solo en el proceso LiveView como `socket.assigns.professional_kek`. Al hacer logout o si el proceso muere, se libera de memoria automáticamente.
- **Formato E.164**: el número de WhatsApp debe normalizarse a E.164 antes de cifrar/hashear para garantizar unicidad del hash (evitar que `+56912345678` y `56912345678` generen hashes distintos).
- **`urgent_intervention`**: campo de base para la feature de alertas clínicas (issues futuras). Se añade aquí porque es parte del modelo de datos base del paciente.
