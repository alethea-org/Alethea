# Alethea: Manual de Ingeniería y Estándares

Este documento define la arquitectura, convenciones y mandatos técnicos innegociables para el desarrollo de Alethea. Todo agente o desarrollador debe adherirse a estos principios.

## 🏗️ Estructura del Proyecto (Modular Monolith)

Seguimos una **Arquitectura Hexagonal**. El "Core" (Lógica de Dominio) debe estar aislado de los "Adapters" (Web, DB, APIs externas).

### Directorios Principales
*   `lib/alethea/`: **Hardened Core (Dominio)**. Contiene la lógica pura.
    *   `accounts/`: Gestión de profesionales y pacientes.
    *   `clinical/`: Diario, grafos de conducta y lógica de intervención.
    *   `encryption/`: Bóveda de llaves (Vault) y lógica de cifrado (Cloak).
    *   `ai/`: Orquestación de modelos (LangChain, Bumblebee).
*   `lib/alethea_web/`: **Web Adapter**. Phoenix, LiveView y controladores de WhatsApp.
*   `lib/alethea_jobs/`: **Infrastructure Adapter**. Workers de Oban para procesamiento asíncrono.

---

## 🔒 Mandatos de Seguridad y Datos

1.  **Cifrado por Paciente:** Todo contenido sensible (mensajes, audios, teléfonos) debe cifrarse con `Cloak.Ecto` utilizando una llave derivada única por paciente.
2.  **Soberanía de Vectores:** Los embeddings en `pgvector` son PII sensible. No deben enviarse a APIs externas sin anonimización previa.
3.  **Transitoriedad de WhatsApp:** WhatsApp es un puerto de entrada. Ningún dato clínico debe persistir en servidores de terceros más allá del tiempo de tránsito.
4.  **Borrado Criptográfico:** El borrado de datos se realiza destruyendo las llaves del paciente en el KMS/Vault.

---

## 🧠 Estándares de IA y Clínica

1.  **Inferencia Híbrida:**
    *   **Local (Bumblebee):** RoBERTa (Sentimiento) y filtros de seguridad. Prioridad: Latencia 0 y privacidad total.
    *   **Orquestada (LangChain):** Phi-4 para conversación guiada. Debe usar una capa de sanitización.
2.  **Persona de la IA:** Tono clínico, neutro y de "personalidad deficiente". Evitar validación de distorsiones cognitivas sin instrucción explícita del terapeuta.
3.  **Trazabilidad (Source Anchoring):** Todo dato en el Dashboard (especialmente en Neo4j) debe tener un puntero (`message_id`) al origen exacto.
4.  **Etiquetado de Inferencia:** Distinguir siempre entre conducta `SPONTANEOUS` (iniciada por paciente) y `ELICITED` (provocada por la IA).

---

## 🛠️ Stack y Convenciones de Código

*   **Lenguaje:** Elixir (Phoenix Framework).
*   **Background Jobs:** Oban (Mandatorio para el pipeline de mensajes).
*   **Bases de Datos:** PostgreSQL (`pgvector`) como fuente de verdad; Neo4j para descubrimiento de patrones.
*   **Testing:**
    *   Tests de Dominio: Sin dependencias externas.
    *   Tests de Integración: Mockear APIs de WhatsApp y LLMs externos.
    *   **Validación Clínica:** Todo cambio en el pipeline de IA debe incluir un test de regresión de sentimiento.

## 🚀 Roadmap Técnico (Iteración 1)
1.  Setup de Phoenix + Oban.
2.  Implementación de `Cloak.Ecto` con esquema de llaves dinámicas.
3.  Webhook de WhatsApp con patrón de "Recibo Transaccional".
