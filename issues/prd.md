# PRD: Alethea MVP - Entrega 1

### Problem Statement
**Para el paciente:** El journaling tradicional genera fricción cognitiva y emocional (el síndrome de la "hoja en blanco"). En momentos de malestar, el esfuerzo de sentarse a escribir reduce la adherencia al registro clínico.
**Para el psicólogo:** La dependencia del relato retrospectivo del paciente introduce sesgos de memoria. Los terapeutas carecen de datos objetivos sobre lo que sucede entre sesiones, perdiendo la oportunidad de intervenir en crisis o basar la terapia en eventos en tiempo real.

### Solution
Alethea es un diario clínico inteligente que transforma el registro emocional en una conversación guiada por WhatsApp. Utiliza IA local (privacidad total) para analizar sentimientos y una capa de IA orquestada para fomentar la reflexión socrática. Los datos se consolidan en un dashboard para el psicólogo, priorizando alertas de riesgo y resúmenes clínicos de alta fidelidad.

### User Stories
1. **Como psicólogo**, quiero registrar a un paciente con su alias y número de WhatsApp, para que el sistema genere automáticamente sus llaves de cifrado únicas.
2. **Como psicólogo**, quiero ver un "Centro de Control de Riesgo" al iniciar sesión, para identificar inmediatamente a pacientes con triggers de crisis detectados el fin de semana.
3. **Como psicólogo**, quiero leer un "Snapshot" pre-sesión (resumen de 4 líneas), para entender los disparadores y emociones predominantes del paciente sin leer todo su chat.
4. **Como paciente**, quiero recibir un mensaje de consentimiento legal al escribir por primera vez, para entender cómo se protegen mis datos antes de empezar.
5. **Como paciente**, quiero que la IA me haga preguntas abiertas y empáticas en WhatsApp, para profundizar en mi registro emocional sin sentirme juzgado.
6. **Como paciente**, quiero que el sistema cierre mi sesión diaria tras 30 minutos de inactividad, para confirmar que mi registro ha sido guardado de forma segura.
7. **Como paciente**, quiero recibir un protocolo de ayuda inmediata si expreso ideas de autolesión, para ser derivado a líneas de asistencia humana.
8. **Como sistema**, quiero cifrar cada mensaje con una llave única derivada por paciente, para garantizar que incluso ante una brecha de base de datos, la PII sea inaccesible.

### Implementation Decisions
- **Módulos**:
    - `Alethea.Clinical.InferencePipeline`: Orquestador de la lógica de IA (Seguridad -> Sentimiento -> Respuesta).
    - `Alethea.Encryption.SecureVault`: Encapsulamiento del esquema de "Double Encryption" (Master Key + Patient Keys).
    - `Alethea.Clinical.SessionManager`: Gestor del estado de la sesión diaria y timeouts vía Oban.
    - `Alethea.Alerts.CrisisMonitor`: Detector de triggers clínicos y despachador de notificaciones de emergencia.
- **Interfaces**:
    - `InferencePipeline.process_input(patient_id, text)`: Devuelve el análisis y la respuesta generada.
    - `SecureVault.encrypt_clinical_data(patient_id, plaintext)`: Provee cifrado determinista y seguro por paciente.
- **Arquitectura**: Modular Monolith en Elixir/Phoenix. PostgreSQL con `pgvector` para el RAG clínico. Procesamiento asíncrono mandatorio con Oban. Inferencia de sentimiento local con Bumblebee (RoBERTa).
- **Líneas Rojas (Prompt Engineering)**: Prohibición absoluta de diagnóstico médico, prohibición de consejos terapéuticos directos y mantenimiento de neutralidad socrática inquebrantable.

### Testing Decisions
- **Calidad**: Los tests deben validar el comportamiento externo del pipeline clínico, no los pesos del modelo.
- **Alcance**: 
    - Tests de regresión para el `CrisisMonitor` (asegurar que palabras clave de riesgo siempre disparen el protocolo).
    - Tests de integración para el `SecureVault` verificando que sin la llave maestra los datos son ilegibles.
    - Tests de flujo de `SessionManager` simulando timeouts de Oban.

### Out of Scope
- Interfaz web para que el paciente lea su propio historial (solo WhatsApp por ahora).
- Registro de notas de voz o imágenes (solo texto para el MVP).
- Gestión de múltiples profesionales o clínicas (single-tenant por ahora).
- Procesamiento de pagos o suscripciones.

### Further Notes
- La interfaz del psicólogo debe ser estrictamente **Light Mode** por requerimiento de diseño.
- Se debe prever la migración a Neo4j para el grafo de conducta en la Entrega 2.