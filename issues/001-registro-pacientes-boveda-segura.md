# Issue 001: Registro de Pacientes y Bóveda Segura

**Type**: AFK
**Blocked by**: None
**User Stories Covered**: 1, 8

## Description
Implementar la interfaz completa para que el psicólogo registre pacientes y asegurar el esquema de seguridad mandatorio por el manual de ingeniería, alineado con la jerarquía de llaves existente (`encryption_keys`) y envelope encryption definidos en el diseño.

## Tasks
- [ ] Finalizar el LiveView de `PatientLive.Index` para permitir la creación de pacientes desde el modal.
- [ ] Implementar la lógica en `Alethea.Accounts.create_patient/1` para:
    - Generar una llave de datos única por paciente para cifrar sus campos sensibles.
    - Proteger esa llave usando la jerarquía de llaves existente (`encryption_keys`) y el esquema de envelope encryption definido en `lib/alethea/DER.md` y `lib/alethea/accounts/CONTEXT.md`, en lugar de una única Master Key.
    - Almacenar el número de WhatsApp cifrado con la llave del paciente y derivar `whatsapp_number_hash` mediante un hash salado/HMAC por profesional para búsquedas, evitando correlación entre terapeutas.
- [ ] Asegurar que el proceso ocurre en una transacción de base de datos.
- [ ] Crear tests de integración en `test/alethea/accounts_test.exs` que verifiquen:
    - Que los datos en la tabla `patients` son ilegibles mediante una consulta SQL directa.
    - Que al borrar o invalidar la llave de datos del paciente dentro del esquema de `encryption_keys`, sus datos se vuelven irrecuperables (Cryptographic Erasure).
