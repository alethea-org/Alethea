---
description: >
  Skill para implementar el esquema de seguridad de Alethea: envelope encryption
  con Cloak.Ecto, jerarquía de llaves por paciente (DEK/KEK), HMAC para búsquedas
  seguras y Cryptographic Erasure. Úsala cuando el usuario pida cifrar un campo
  nuevo, gestionar llaves de paciente, o implementar borrado seguro.
---

# Skill: Encryption Vault — Alethea Security Core

## Cuándo Invocarme

Invoca esta skill cuando el usuario pida:
- Cifrar un campo nuevo en un schema Ecto con `Cloak.Ecto`
- Implementar la generación o rotación de llaves de paciente (DEK/KEK)
- Añadir un hash seguro para búsquedas (sin exponer PII)
- Implementar Cryptographic Erasure (borrado seguro por destrucción de llave)
- Crear tests que verifiquen que los datos son ilegibles sin la llave

## Lo Que Hago

1. **Leo el contexto de cifrado** en `lib/alethea/encryption/` y `lib/alethea/DER.md`
   para entender la jerarquía de llaves actual.

2. **Implemento con Cloak.Ecto** siguiendo el patrón DEK/KEK:
   - DEK (Data Encryption Key): única por paciente, cifra sus campos sensibles
   - KEK (Key Encryption Key): del profesional, protege las DEKs
   - Las DEKs nunca se almacenan en claro, solo cifradas con la KEK

3. **Genero HMAC** para campos que requieren búsqueda sin exponer PII:
   - `whatsapp_number_hash = HMAC-SHA256(phone, psychologist_id)`
   - Evita correlación de pacientes entre terapeutas diferentes

4. **Implemento Cryptographic Erasure**:
   - Invalidar/destruir la DEK del paciente en `encryption_keys`
   - Los datos en `patients` se vuelven irrecuperables

5. **Escribo tests** que verifiquen opacidad SQL y erasure.

## Restricciones Que Aplico Siempre

| Restricción | Implementación |
|-------------|----------------|
| Sin PII en claro | `Cloak.Ecto.Binary` en todo campo sensible |
| Sin búsqueda en claro | `*_hash` HMAC para lookup, no el campo cifrado |
| Sin DEK en claro | DEKs almacenadas cifradas con KEK en `encryption_keys` |
| Sin correlación | HMAC usa `psychologist_id` como sal, diferente por terapeuta |
| Borrado seguro | Destruir DEK hace los datos irrecuperables |

## Patrón de Implementación

### Agregar campo cifrado a un schema existente

```
1. Generar migración: mix ecto.gen.migration add_encrypted_<field>_to_<table>
2. Cambiar tipo de columna a :binary
3. Actualizar el schema: field :<name>, Cloak.Ecto.Binary
4. Actualizar changeset: NO incluir el campo en cast (se setea programáticamente)
5. Crear test de opacidad: verificar que SELECT devuelve binario, no texto
```

### Agregar campo de búsqueda (HMAC)

```
1. Generar migración para columna *_hash :string
2. Calcular hash en la lógica de creación/actualización
3. Usar el hash en queries WHERE, nunca el campo cifrado
4. Test: verificar que el hash es diferente para mismo valor + distinto psychologist
```

## Referencias del Proyecto

- **Diseño de llaves**: `lib/alethea/DER.md`
- **Contexto del módulo**: `lib/alethea/encryption/`
- **Instrucciones de Accounts**: `.github/instructions/accounts.instructions.md`
- **HexDocs Cloak.Ecto**: https://hexdocs.pm/cloak_ecto/
