# SDD Design: KEK Ownership Validation

## Change: `auth-kek-ownership-validation`

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Browser Session                           │
│  { professional_id: "abc123", _csrf_token: "xyz" }          │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│              ProfessionalAuth.on_mount/4                    │
│                                                             │
│  1. Extract professional_id from session                    │
│  2. Load professional from DB                                │
│  3. Verify KEK file exists for this professional_id          │ ◄── NEW
│  4. If exists → load KEK into socket                          │
│  5. If not exists → halt and redirect to /login              │
│  6. Log KEK_ACCESS in audit_logs                             │ ◄── NEW
└─────────────────────────────────────────────────────────────┘
                              │
                    ┌──────────┴──────────┐
                    ▼                     ▼
            ┌───────────────┐    ┌─────────────────┐
            │   SUCCESS    │    │     FAILURE     │
            │              │    │                 │
            │ Load KEK     │    │ Redirect /login │
            │ Assign to    │    │ Flash: error    │
            │ socket       │    │ Log failure     │
            └───────────────┘    └─────────────────┘
```

---

## Implementation Details

### 1. ProfessionalKek Module Changes

**File**: `lib/alethea/encryption/professional_kek.ex`

Add new function:
```elixir
@doc """
Verifies that a KEK file exists for the given professional.
Returns {:ok, path} if exists, {:error, :not_found} if not.
"""
def verify_kek_exists(professional_id) do
  path = kek_path(professional_id)
  if File.exists?(path), do: {:ok, path}, else: {:error, :not_found}
end
```

### 2. ProfessionalAuth.on_mount Changes

**File**: `lib/alethea_web/plugs/professional_auth.ex`

Modify `on_mount(:mount_current_professional, ...)`:

```elixir
def on_mount(:mount_current_professional, _params, session, socket) do
  case session["professional_id"] do
    nil ->
      {:cont, Phoenix.Component.assign(socket, :current_professional, nil)}

    professional_id ->
      try do
        professional = Accounts.get_professional!(professional_id)

        # NEW: Verify KEK ownership
        with {:ok, _path} <- ProfessionalKek.verify_kek_exists(professional_id),
             {:ok, kek} <- Accounts.load_professional_kek(professional) do

          # NEW: Log KEK access
          Accounts.log_action(%{
            action: "KEK_ACCESS",
            professional_id: professional.id,
            resource_type: "KEK",
            resource_id: nil,
            details: %{result: :success}
          })

          {:cont,
           socket
           |> Phoenix.Component.assign(:current_professional, professional)
           |> Phoenix.Component.assign(:professional_kek, kek)}
        else
          {:error, :not_found} ->
            log_kek_failure(professional_id, :not_found)
            {:halt, redirect_with_error(socket, "Sesión inválida.")}

          {:error, reason} ->
            log_kek_failure(professional_id, reason)
            {:halt, redirect_with_error(socket, "Sesión inválida. Por favor, iniciá sesión nuevamente.")}
        end
      rescue
        e in Ecto.NoResultsError ->
          {:cont, Phoenix.Component.assign(socket, :current_professional, nil)}
        e ->
          {:cont, Phoenix.Component.assign(socket, :current_professional, nil)}
      end
  end
end

# NEW private functions
defp log_kek_failure(professional_id, reason) do
  Logger.warning("KEK validation failed for #{professional_id}: #{inspect(reason)}")

  # Don't log if professional_id is nil (avoid DB write on anonymous)
  if professional_id do
    try do
      Accounts.log_action(%{
        action: "KEK_ACCESS",
        professional_id: professional_id,
        resource_type: "KEK",
        resource_id: nil,
        details: %{result: reason}
      })
    rescue
      _ -> :ok  # Don't fail auth if audit fails
    end
  end
end

defp redirect_with_error(socket, message) do
  Phoenix.LiveView.redirect(socket,
    to: "/login",
    flash: %{error: message}
  )
end
```

---

## Test Plan

### Unit Tests (ProfessionalAuth)

**File**: `test/alethea_web/plugs/professional_auth_test.exs`

```elixir
defmodule AletheaWeb.Plugs.ProfessionalAuthTest do
  use AletheaWeb.ConnCase, async: false

  describe "KEK ownership validation" do
    test "valid session loads KEK successfully", %{conn: conn} do
      # Setup: Create professional with KEK
      professional = setup_professional_with_kek()

      # Action: Navigate with valid session
      conn =
        conn
        |> init_test_session(%{professional_id: professional.id})
        |> get("/dashboard")

      # Assert: KEK loaded, redirected to dashboard
      assert html_response(conn, 200)
      assert get_session(conn, :professional_id) == professional.id
    end

    test "session with non-existent professional_id redirects to login" do
      # Action: Navigate with invalid professional_id
      conn =
        conn
        |> init_test_session(%{professional_id: "fake-id"})
        |> get("/dashboard")

      # Assert: Redirected to login
      assert redirected_to(conn) == "/login"
      assert get_flash(conn, :error) =~ "Sesión inválida"
    end

    test "missing KEK file redirects to login", %{conn: conn} do
      # Setup: Professional exists but KEK deleted
      professional = setup_professional_without_kek()

      # Action
      conn =
        conn
        |> init_test_session(%{professional_id: professional.id})
        |> get("/dashboard")

      # Assert
      assert redirected_to(conn) == "/login"
    end
  end
end
```

### Integration Test (AuditLog)

```elixir
test "KEK access is logged to audit_logs" do
  professional = setup_professional_with_kek()

  conn
  |> init_test_session(%{professional_id: professional.id})
  |> get("/dashboard")

  # Assert audit log entry
  audit_entry =
    Repo.get_by(AuditLog,
      professional_id: professional.id,
      action: "KEK_ACCESS"
    )

  assert audit_entry
  assert audit_entry.details == %{result: :success}
end
```

---

## Files to Modify

| File | Change |
|------|--------|
| `lib/alethea/encryption/professional_kek.ex` | Add `verify_kek_exists/1` |
| `lib/alethea_web/plugs/professional_auth.ex` | Add ownership validation, logging, error handling |

## Files to Create

| File | Purpose |
|------|---------|
| `test/alethea_web/plugs/professional_auth_test.exs` | Unit and integration tests |

---

## Rollback Procedure

1. Remove `verify_kek_exists/1` from `ProfessionalKek`
2. Remove KEK ownership check from `on_mount`
3. Remove audit log call in KEK access path
4. Keep error handling (redirect on KEK load failure)

---

**Status**: DESIGN
**Author**: el Gentleman
**Created**: 2026-06-01