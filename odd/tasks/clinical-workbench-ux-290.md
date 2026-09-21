# Feature: Mejorar UX clínica del workbench de análisis funcional (#290)

## Contexto y objetivos
El workbench de análisis funcional (`/patients/:patient_id/target_behaviors/:id/review`) debe guiar al profesional durante el razonamiento clínico sin modificar el modelo de datos existente.

Criterios de aceptación:
- [x] El psicólogo ve claramente paciente y conducta objetivo en la cabecera.
- [x] La pantalla muestra estados vacíos clínicamente útiles.
- [x] El botón `Sugerir patrones (IA)` solo está disponible cuando hay evidencia suficiente, o explica por qué no lo está.
- [x] Cada acción principal tiene feedback visible y específico.
- [x] Tests LiveView cubren estados vacíos, botón de IA habilitado/deshabilitado y feedback de acciones.

## Tareas

- [x] Task 1: Descifrado de conducta objetivo y contexto clínico en `ClinicalRecord` (commit: `1a1d536`)
- [x] Task 2: Cabecera clínica y contadores en el workbench
- [x] Task 3: Guardas y feedback para botón de IA (evidencia suficiente)
- [x] Task 4: Estados vacíos explícitos (evidencia, observaciones, propuestas, borrador)
- [x] Task 5: Feedback contextual de acciones y confirmación suave para descartar
- [x] Task 6: Pruebas LiveView exhaustivas y verificación con `mix precommit`
