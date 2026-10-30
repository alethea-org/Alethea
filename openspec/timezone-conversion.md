# IANA timezone conversion

`Alethea.Accounts.Timezone` validates IANA identifiers and converts a local
`Date` and `Time` into UTC with the bundled rules from `tz ~> 0.28`.

```elixir
Timezone.convert_to_utc("America/Argentina/Buenos_Aires", ~D[2024-01-10], ~T[10:00:00])
# {:ok, ~U[2024-01-10 13:00:00Z]}
```

All returned instants use `Etc/UTC`:

- `{:ok, datetime}` for an unambiguous local time.
- `{:ambiguous, earlier, later}` when a local time occurs twice during fall-back.
- `{:gap, before_gap, after_gap}` when a local time does not exist during spring-forward.
- `{:error, :time_zone_not_found}` for an unknown zone.
- `{:error, :invalid_arguments}` for unsupported argument types.

Callers must resolve gaps and overlaps explicitly; conversion never silently
chooses a different local time. `valid?/1` and `validate_timezone/2` provide
identifier validation for domain changesets.

The database is passed explicitly as `Tz.TimeZoneDatabase`; global Calendar
configuration and existing UTC session calculations remain unchanged. No updater
process is started. IANA rule updates require a controlled `mix deps.update tz`
upgrade and tests; runtime conversions do not download data.
