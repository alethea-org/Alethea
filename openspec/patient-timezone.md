# Patient Timezone & Local-to-UTC Conversion

## Overview

This specification documents the timezone model introduced for patients and professionals (Issue #439, S1-S6).
It establishes:
1. Timezone persistence and inheritance on `Alethea.Accounts.Professional` and `Alethea.Accounts.Patient`.
2. Domain update flows and dashboard edit paths for professionals and patients.
3. Domain conversion contracts for mapping local wall times to UTC, including daylight saving time (DST) transitions.
4. Scope boundary excluding session schedule UTC migration.
5. Manual update policy for the `tz` dependency.

---

## 1. Field Inheritance (Future Creations Only)

- Both `professionals` and `patients` tables carry a `:timezone` column (`:string`, `default: "Etc/UTC"`, `null: false`).
- When a new patient is created via `Alethea.Accounts.create_patient/2` (encrypted with KEK) or `Alethea.Accounts.create_patient/1` (fallback):
  - If `:timezone` / `"timezone"` is not provided or is blank in attributes, the patient inherits the owning professional's current `timezone`.
  - If the professional has no timezone or cannot be resolved, it falls back to `"Etc/UTC"`.
- **Inheritance is snapshot-based and non-retroactive**: Updating a professional's timezone later does **not** rewrite existing patients' timezones. Existing patients retain their assigned timezone unless explicitly edited.

---

## 2. Domain Updates & Validation

- Professional timezone persists via `Alethea.Accounts.update_professional/2`.
- Patient timezone persists via `Alethea.Accounts.update_patient/2` (atom-key attributes) or `Alethea.Accounts.update_patient_timezone/2`.
- Both schemas use `Alethea.Accounts.Timezone.validate_timezone/2` to reject invalid or blank IANA identifiers without changing persisted state.
- Callers must resolve the patient using the authenticated professional's ownership scope before updating it.

---

## Dashboard Edit Paths

- Professional settings: open `#bot-settings` and submit `#professional-timezone-form` (`save_professional_timezone`). This changes the default for future patients only.
- Patient briefing: submit `#patient-timezone-form` (`save_patient_timezone`) for the selected patient.
- Both forms reject invalid or blank timezone inputs with an error flash, leave persisted state unchanged, and reset to the persisted value.
- Patient updates resolve ownership via `Accounts.get_patient_for_professional/2` using the authenticated professional and socket-selected patient. Client-supplied patient IDs are ignored.
- Mock mode updates assigns in memory only, without writing patient or professional timezones to the database.
- Existing session scheduling remains UTC; the patient timezone is the reference for future active triggers, not a reinterpretation of the session time.

---

## 3. Local-to-UTC Conversion Contract (DST & Boundary Cases)

The domain conversion functions:
- `Alethea.Accounts.PatientTimezone.convert_to_utc(patient, date, time)`
- `Alethea.Accounts.convert_patient_local_to_utc(patient, date, time)`
- `Alethea.Accounts.Timezone.convert_to_utc(timezone, date, time)`

### Contract Signatures and Return Values
Accepts:
- `patient`: `%Patient{}` or map with `:timezone`
- `date`: `%Date{}`
- `time`: `%Time{}`

Returns:
- `{:ok, %DateTime{}}`: Instant in UTC (`time_zone: "Etc/UTC"`).
- `{:ambiguous, %DateTime{}, %DateTime{}}`: During fall-back DST transitions (clocks set backward 1 hour, wall time occurs twice). Both returned instants are explicitly converted to UTC. Calling services choose resolution explicitly; the domain service never guesses silently.
- `{:gap, %DateTime{}, %DateTime{}}`: During spring-forward DST transitions (clocks skip forward 1 hour, wall time does not exist). Both boundary instants before and after the gap are explicitly converted to UTC.
- `{:error, :time_zone_not_found}`: If the timezone identifier is not found in the IANA database.
- `{:error, :invalid_arguments}`: If non-date/non-time structures are supplied.

---

## 4. UTC Session Schedule Exclusion

- As specified in S1, the existing session scheduling fields (`session_day_of_week`, `session_time`) and `Alethea.Accounts.SessionSchedule` continue to operate strictly in UTC.
- Migrating existing session schedule storage off UTC is explicitly out of scope for this change.
- Patient timezone serves as the foundation for future local-time triggers without altering current UTC session reminder behavior.

---

## 5. Dependency & IANA Database Update Policy

- Implemented using `tz ~> 0.28`.
- `Tz.TimeZoneDatabase` is passed explicitly to `DateTime.new/4` and `DateTime.shift_zone/3`.
- **No global Calendar configuration change**: `Calendar.put_time_zone_database` is not called to prevent unintended global side effects on existing UTC-only modules.
- **No background update processes**: No periodic HTTP downloaders or background updaters run. All timezone rules are compiled and bundled deterministically offline.
- **Update policy**: IANA updates occur exclusively through controlled library upgrades via `mix deps.update tz` during scheduled maintenance, ensuring reproducible builds and deterministic test execution.
