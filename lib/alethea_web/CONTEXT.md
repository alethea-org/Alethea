# Web Interface: `lib/alethea_web/`

Este es el **Adaptador de Entrada** para el mundo exterior (HTTP, WebSockets).

## Propósito
Gestionar las peticiones de los usuarios y profesionales, traduciéndolas en llamadas al núcleo de la aplicación.

## Sub-módulos
*   **`controllers/`**: Maneja peticiones HTTP tradicionales y Webhooks (ej. Telegram).
*   **`live/`**: Dashboard profesional reactivo usando Phoenix LiveView.
*   **`components/`**: Componentes visuales reutilizables.
*   **`router.ex`**: Define los puntos de entrada y los pipelines de seguridad (browser, api).

## Guía para Desarrolladores y Agentes
1.  **Delgadez**: Los controladores y LiveViews deben ser "delgados". No pongas lógica de negocio aquí; delega a los módulos en `lib/alethea/`.
2.  **Seguridad**: Asegúrate de aplicar los Plugs de autenticación y MFA en el router para las rutas del profesional.
3.  **UI Clínica**: El Dashboard debe priorizar la legibilidad y el "Light Mode" según el manifiesto.
