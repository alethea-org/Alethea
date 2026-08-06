# Diseño de Entidad-Relación (DER) - Alethea

Este documento detalla la arquitectura de datos relacional de Alethea, diseñada para cumplir con estándares clínicos, seguridad de alto nivel (GDPR/HIPAA-ready) y un presupuesto eficiente (<$800 USD).

## 📊 Diagrama de Tablas

### 1. Núcleo de Identidad e Infraestructura (`Accounts`)
*   **`professionals`**: Usuarios del portal (psicólogos).
*   **`patients`**: Identidades anonimizadas de pacientes. Vinculados 1:N con profesionales.
*   **`encryption_keys`**: Gestión de llaves (Envelope Encryption). Soporta Borrado Criptográfico.
*   **`audit_logs`**: Registro inmutable de acciones sensibles (quién vio qué y cuándo).

### 2. Transaccionalidad Clínica (`Clinical`)
*   **`messages`**: Registro de interacciones de WhatsApp. Almacenamiento cifrado con IV incluido.
*   **`clinical_trends`**: Capa de indicadores (Ansiedad, Sueño, etc.) para seguimiento de progreso.
*   **`clinical_summaries`**: Consolidados periódicos generados por IA para el dashboard del profesional.

### 3. Inteligencia Artificial (`AI`)
*   **`ai_diagnoses`**: Resultados de inferencia (RoBERTa/Phi-4). Relación 1:N con mensajes para permitir múltiples modelos o re-procesamiento.

---

## 🧠 Racional de Decisiones Arquitectónicas (ADRs)

### ADR 01: Jerarquía de Llaves (Envelope Encryption)
**Contexto:** El borrado de datos físico en backups es complejo y lento.
**Decisión:** Cada paciente tiene una llave única cifrada por la llave del profesional.
**Impacto:** Permite el **Borrado Criptográfico**. Destruyendo la llave del paciente, sus datos se vuelven ruido ilegible instantáneamente sin afectar a otros pacientes.

### ADR 02: Privacidad entre Profesionales (Salted Hash) — RETIRADO
**Contexto:** Un paciente puede atenderse con múltiples terapeutas que usen Alethea.
**Decisión (histórica):** El `whatsapp_number_hash` se generaba con una sal (salt) única por profesional.
**Estado:** Retirado en #107 junto con la superficie de identidad de WhatsApp (WhatsApp se retiró en #87). El alias es hoy el identificador de registro; la unicidad de identidad vive en el `telegram_chat_id_hash` de foundation.

### ADR 03: Relación 1:N en Diagnósticos de IA
**Contexto:** Los modelos de IA evolucionan rápidamente.
**Decisión:** Un mensaje puede tener múltiples registros en `ai_diagnoses`.
**Impacto:** Permite comparar resultados de diferentes modelos o re-analizar mensajes antiguos con versiones más modernas de la IA sin perder el historial.

### ADR 04: Tabla de Tendencias (`Clinical Trends`)
**Contexto:** Los psicólogos necesitan ver evolución, no solo fotos fijas.
**Decisión:** Capa de datos numéricos derivada del análisis de texto.
**Impacto:** Facilita la creación de gráficas de progreso en tiempo real y reduce la carga computacional de procesar miles de mensajes cada vez que se carga el dashboard.

### ADR 05: Versiones de Cifrado (`encryption_version`)
**Contexto:** Los estándares criptográficos caducan.
**Decisión:** Cada registro cifrado lleva un número de versión.
**Impacto:** Permite la coexistencia de diferentes algoritmos y facilita la rotación de llaves o migración de algoritmos sin tiempos de inactividad.

---

## 🛠️ Especificaciones Técnicas
*   **Base de Datos:** PostgreSQL con extensiones `pgvector`.
*   **IDs:** UUIDv4 (`binary_id`) en todas las tablas para evitar enumeración y facilitar sincronización con Neo4j.
*   **Cifrado:** AES-256-GCM (vía Cloak.Ecto).
