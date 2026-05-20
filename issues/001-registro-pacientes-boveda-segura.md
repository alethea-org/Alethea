# Issue 001: Registro de Pacientes y Bóveda Segura

**Type**: AFK
**Blocked by**: None
**User Stories Covered**: 1, 8

## Description
Implementar la interfaz completa para que el psicólogo registre pacientes y asegurar el esquema de seguridad de "Double Encryption" mandatorio por el manual de ingeniería.

## Tasks
- [ ] Finalizar el LiveView de `PatientLive.Index` para permitir la creación de pacientes desde el modal.
- [ ] Implementar la lógica en `Alethea.Accounts.create_patient/1` para:
    - Generar una llave AES-256 única por paciente.
    - Cifrar dicha llave con la Master Key de la aplicación (`Alethea.Encryption.Vault`).
    - Almacenar el número de WhatsApp cifrado con la llave del paciente y su hash (SHA256) para búsquedas.
- [ ] Asegurar que el proceso ocurre en una transacción de base de datos.
- [ ] Crear tests de integración en `test/alethea/accounts_test.exs` que verifiquen:
    - Que los datos en la tabla `patients` son ilegibles mediante una consulta SQL directa.
    - Que al borrar la llave del paciente, sus datos se vuelven irrecuperables (Cryptographic Erasure).
