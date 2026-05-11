# Accounts & Profiles: `lib/alethea/accounts/`

Gestión de los usuarios de la plataforma: Psicólogos (profesionales) y Pacientes (clientes).

## Propósito
Manejar el registro, autenticación y la relación jerárquica entre el terapeuta y sus pacientes.

## Seguridad
*   **MFA**: Mandatorio para profesionales debido a la sensibilidad de los datos.
*   **Aislamiento**: Un psicólogo nunca debe poder ver los datos de los pacientes de otro colega.

## Guía para Desarrolladores y Agentes
1.  **Contextos de Phoenix**: Usa este módulo para todas las queries relacionadas con la identidad de los usuarios.
2.  **Vinculación**: Asegúrate de que cada paciente esté estrictamente vinculado a un `professional_id`.
