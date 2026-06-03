# Alethea 🧠

> **Diario interactivo y sensor de conducta verbal para la continuidad terapéutica.**

## 📋 Visión del Proyecto

Para psicólogos que trabajan con información fragmentada y sesgada de sus pacientes, **Alethea** es una plataforma de journaling interactivo que convierte las vivencias diarias en registros clínicos estructurados y objetivos en tiempo real.

A diferencia del journaling manual, nuestro producto simplifica el registro mediante una conversación guiada vía WhatsApp, permitiendo al profesional expandir su visión diagnóstica con datos ya organizados para la sesión.

---

## 🏗️ Arquitectura Técnica

El proyecto se basa en un **Monolito Modular** bajo **Arquitectura Hexagonal**, priorizando la soberanía de los datos y la resiliencia clínica.

### Stack Tecnológico

*   **Backend:** [Phoenix Framework (Elixir)](https://phoenixframework.org/) para alta concurrencia y gestión de estado en tiempo real.
*   **IA Orchestration:** [LangChain](https://github.com/elixir-langchain/langchain) con **RoBERTa** (análisis de sentimiento local vía `Nx/Bumblebee`) y **Phi-4 mini** (conversación guiada).
*   **Bases de Datos:**
    *   **PostgreSQL + pgvector:** Almacenamiento principal y búsqueda semántica de vectores protegidos.
    *   **Neo4j:** Mapeo de grafos de conducta verbal (probabilísticos y pendientes de verificación clínica).
*   **Infraestructura:**
    *   **WhatsApp Business API:** Tratada como un **Puerto Transitorio** (sin persistencia en el proveedor).
    *   **Oban:** Procesamiento asíncrono para garantizar el patrón de **Recibo Transaccional** y mitigar la latencia de inferencia.

---

## 🔒 Seguridad y Privacidad (Innegociable)

*   **Soberanía de Datos:** Cifrado en reposo mediante `Cloak.Ecto` (AES-256). Las llaves son específicas por paciente, permitiendo el **Borrado Criptográfico** al finalizar el proceso terapéutico.
*   **Protección de Vectores:** Los embeddings se tratan como PII sensible, protegidos con el mismo rigor que el texto plano para evitar ataques de inversión.
*   **Auditoría Clínica:** Registro estricto de accesos y modificaciones, asegurando que la "Verdad Clínica" sea siempre trazable al origen.
*   **Interfaz:** Dashboard diseñado exclusivamente para **Light Mode** para asegurar legibilidad en entornos clínicos.

---

## ⚖️ Principios Éticos y de IA

*   **IA de Personalidad Deficiente:** El bot mantiene un tono clínico y neutro para evitar el "Atrapamiento de Transferencia" y preservar el vínculo humano con el terapeuta.
*   **Seguridad Determinista:** Filtro de "Banderas Rojas" por palabras clave que opera en paralelo a la IA para detección inmediata de crisis sin depender de la "intuición" del modelo.
*   **Transparencia de Fuente:** Cada hallazgo o nodo del grafo incluye un enlace directo al mensaje original o al audio (Whisper) para evitar el sesgo de automatización.
*   **Matiz Acústico:** La transcripción de sesiones incluye metadatos de prosodia (silencios, tono, velocidad) para no perder la carga emocional del lenguaje no verbal.

### Lo que Alethea NO es
*   🚫 **NO** es un servicio de intervención en crisis.
*   🚫 **NO** diagnostica de forma autónoma ni genera juicios clínicos finales.
*   🚫 **NO** sustituye el juicio ni la supervisión activa del profesional.

---

## 🔐 Estado de Seguridad

### Implementado ✅
- **Cifrado AES-256-GCM** con envelope encryption (DEK por paciente)
- **PBKDF2** para passwords
- **HMAC-SHA256** para hashing de números de teléfono
- **CSRF Protection** en sesiones
- **Auditoría** de accesos PII
- **Rate Limiting** basado en ETS
- **Sanitización de PII** antes de enviar a LLM
- **Detección de crisis** con patrones configurables
- **Consentimiento GDPR** via flujo ACEPTO

### Pendiente (v2) 🔜
- **MFA/TOTP** para profesionales (schema preparado, flujo pendiente)
- **Rotación de KEK** (criptográfica)
- **pgvector** para RAG semántico
- **Neo4j** para grafo de conducta
- **Whisper** para transcripción de voz

---

## 🚀 Roadmap de Desarrollo

1.  **Iteración 1:** Core de mensajería (WhatsApp asíncrono) + Cifrado base (`Cloak.Ecto`).
2.  **Iteración 2:** Implementación de RAG Protegido y Dashboard de visualización inicial.
3.  **Iteración 3:** RAG de Voz (Whisper) con integración de matices acústicos.
4.  **Iteración 4:** Triggers Deterministas y detección de patrones de riesgo.
5.  **Iteración 5:** Módulo de analítica avanzada y exportación de datos (Portabilidad).
6.  **Iteración 6:** Auditoría de seguridad final y cumplimiento normativo.

---

Este proyecto se desarrolla en cumplimiento de los requisitos académicos de la materia Proyecto Final.
