# Alethea 🧠

> **Diario interactivo y sensor de conducta verbal para la continuidad terapéutica.**

## 📋 Visión del Proyecto

Para psicólogos que trabajan con información fragmentada y sesgada de sus pacientes , **Alethea** es una plataforma de journaling interactivo que convierte las vivencias diarias en registros clínicos estructurados y objetivos en tiempo real.

A diferencia del journaling manual, nuestro producto simplifica el registro mediante una conversación guiada vía WhatsApp, permitiendo al profesional expandir su visión diagnóstica con datos ya organizados para la sesión.

### ¿Por qué existimos?

* **Eliminar el sesgo de memoria:** Evita que el paciente dependa de recordar detalles días después del evento.


* **Journaling en tiempo real:** Registro de emociones en el momento exacto en que ocurren.


* **Optimización de la sesión:** El psicólogo se enfoca en acompañar el presente con datos objetivos en lugar de reconstruir el pasado.


* **Continuidad terapéutica:** Transforma la terapia en un puente de comunicación constante.



---

## 🏗️ Arquitectura Técnica

El proyecto está construido bajo un paradigma de **Monolito Modular** aplicando **Arquitectura Hexagonal (Ports & Adapters)** para garantizar la mantenibilidad y la soberanía de los datos.

### Stack Tecnológico

* **Backend:** [Phoenix Framework (Elixir)](https://www.google.com/search?q=https://phoenixframework.org/) para alta concurrencia y tolerancia a fallos.


* **IA Orchestration:** [LangChain](https://www.google.com/search?q=https://github.com/elixir-langchain/langchain) utilizando modelos **RoBERTa** (análisis de emociones) y **Phi-4 mini** (conversación guiada).


* **Bases de Datos:** * **PostgreSQL** con extensión `pgvector` para búsqueda semántica y RAG.
* **Neo4j** para el mapeo de grafos de conducta verbal.




* **Infraestructura de Mensajería:** **WhatsApp Business API** como interfaz principal.


* **Background Jobs:** **Oban** para el procesamiento asíncrono y resiliente de mensajes de IA.

---

## 🔒 Seguridad y Privacidad (Innegociable)

La seguridad y la precisión clínica son la prioridad máxima del proyecto.

* **Cifrado en Reposo:** Implementado mediante `Cloak.Ecto` con algoritmos AES-256 para todo contenido sensible (registros de diario y números de teléfono).
* **Auditoría Clínica:** Registro estricto de accesos a los datos del paciente por parte de los profesionales.
* **Interfaz:** El Dashboard profesional está diseñado exclusivamente para **Light Mode** para asegurar legibilidad en entornos clínicos.

### Lo que Alethea NO es

* 🚫 NO diagnostica de forma autónoma.


* 🚫 NO reemplaza la terapia presencial/virtual.


* 🚫 NO funciona sin supervisión profesional activa.



---

## 🚀 Roadmap de Desarrollo

El proyecto se desarrolla en un ciclo de **6 meses (6 iteraciones)**:

1. **Iteración 1:** Core de mensajería WhatsApp + Cifrado base.
2. **Iteración 2:** Implementación de RAG y Chat para el profesional.
3. **Iteración 3:** Integración de Whisper para transcripción de sesiones (RAG de voz).
4. **Iteración 4:** Configuración de Triggers Activos y Pasivos para detección de crisis.
5. **Iteración 5:** Módulo de Pricing y analítica clínica avanzada.
6. **Iteración 6:** Pruebas de seguridad y cumplimiento normativo.

---

Este proyecto se desarrolla en cumplimiento de los requisitos académicos de la materia Proyecto Final.

---
