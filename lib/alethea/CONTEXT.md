# Hardened Core: `lib/alethea/`

Este directorio contiene la **Lógica de Dominio** pura de la aplicación, aislada de las interfaces web y de la infraestructura de base de datos. Siguiendo los principios de **Arquitectura Hexagonal**, aquí reside la "verdad" del negocio y la clínica.

## Propósito para Desarrolladores
Si eres nuevo en Phoenix, piensa en esta carpeta como el lugar donde defines **qué hace** la aplicación, sin preocuparte de **cómo se muestra** o **de dónde vienen los datos**. Aquí no encontrarás controladores ni plantillas HTML.

## Sub-módulos y Responsabilidades
*   **`accounts/`**: Gestión de identidades (Psicólogos y Pacientes).
*   **`clinical/`**: El motor terapéutico. Maneja diarios, grafos de conducta y triggers de crisis.
*   **`encryption/`**: La bóveda de seguridad. Gestiona las llaves dinámicas y el cifrado AES-256.
*   **`ai/`**: Orquestación de inteligencia artificial. Aquí es donde LangChain une los modelos con los datos clínicos.

## Guía para Agentes de IA
Al trabajar en esta carpeta:
1.  **Mantén la pureza:** No importes módulos de `AletheaWeb`.
2.  **Seguridad primero:** Toda función que maneje datos de pacientes debe pasar por el módulo de `Encryption`.
3.  **Tipado fuerte:** Usa `typespecs` (@spec) para definir claramente las entradas y salidas de las funciones clínicas.
