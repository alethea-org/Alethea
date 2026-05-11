# Encryption Vault: `lib/alethea/encryption/`

Este es el componente más crítico para la **Soberanía de Datos**. Se encarga de que nadie, excepto el profesional autorizado, pueda leer el contenido de los diarios.

## Propósito
Gestionar el ciclo de vida de las llaves criptográficas y aplicar cifrado AES-256 a los datos sensibles antes de que toquen el disco.

## Tecnologías
*   **Cloak.Ecto**: Integración con la base de datos para cifrado automático.
*   **Key Derivation**: Lógica para derivar llaves únicas por paciente a partir de un Master Key.

## Guía para Desarrolladores y Agentes
1.  **Innegociable:** No guardes llaves maestras en el código ni en la base de datos en claro.
2.  **Transparencia:** El cifrado debe ser invisible para la lógica de dominio (gracias a Cloak), pero explícito en las migraciones de base de datos.
3.  **Borrado Criptográfico:** Cualquier función de "Eliminar cuenta" debe invocar la destrucción de la llave del paciente en este módulo.
