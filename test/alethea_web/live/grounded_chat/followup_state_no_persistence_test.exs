defmodule AletheaWeb.GroundedChat.FollowupStateNoPersistenceTest do
  @moduledoc """
  Enforcement mecánico del invariante #1 de
  `AletheaWeb.GroundedChat.FollowupState`: el módulo sólo puede
  referenciarse desde la ruta LiveView designada para el chat de
  consulta fundamentada.

  Cualquier referencia al símbolo `FollowupState` (o a su assign
  `followup_state`) bajo `lib/` que **no** esté explícitamente en
  `@allowed_lib_paths` rompe este test. Esa referencia es un bug de
  ADR-010 §6: el estado dejó el alcance del proceso LiveView.

  ## Cómo ampliar la allowlist legítimamente

  Cuando una issue hermana (#226, #227, #233, #236) integre el
  estado en su código, se debe agregar la ruta absoluta del archivo
  a `@allowed_lib_paths` con un comentario que diga qué issue y por
  qué ese archivo es parte del seam LiveView permitido.

  Una referencia típica a permitir:

      # A2 (issue #227) — la carcasa LiveView del chat; asigna
      # el estado en mount/3. Es exactamente el seam LiveView
      # previsto por ADR-010 §6.
      "lib/alethea_web/live/consultation_live.ex",

  Una referencia que **nunca** debe entrar en la allowlist:

      # Cualquier `lib/alethea/...` (fuera de alethea_web/): el
      # dominio no puede leer ni escribir el estado.
      "lib/alethea/clinical/..."  # ← NO permitido
  """

  use ExUnit.Case, async: true

  # Rutas bajo `lib/` permitidas para referenciar `FollowupState`.
  # Cada entrada debe tener un comentario justificando la inclusión
  # (issue + motivo). El módulo `followup_state.ex` mismo siempre
  # está permitido; está fuera de la allowlist porque se detecta por
  # convención (es el archivo que define el módulo).
  @allowed_lib_paths [
    # B1 (issue #228): el propio módulo define el seam.
    # Excluido por convención; ver `lib_root_basenames/0` abajo.

    # A2 (issue #227) — la carcasa LiveView del chat; asigna el
    # estado en mount/3 y lo resetea en "nueva conversación". Es
    # exactamente el seam LiveView previsto por ADR-010 §6.
    "lib/alethea_web/live/consultation_live.ex"
  ]

  # Tests pueden referenciar FollowupState libremente.
  @allowed_test_paths [
    "test/alethea_web/live/grounded_chat/followup_state_test.exs",
    "test/alethea_web/live/grounded_chat/followup_state_no_persistence_test.exs"
  ]

  @lib_root "lib/"
  @test_root "test/"
  @module_basename "followup_state.ex"

  @doc """
  Detecta referencias literales a `FollowupState` o al assign
  `followup_state` en el código bajo `lib/`. Excluye el archivo
  que define el módulo.
  """
  def find_lib_references do
    Path.wildcard("lib/**/*.ex")
    |> Enum.reject(&String.ends_with?(&1, @module_basename))
    |> Enum.flat_map(&scan_file/1)
  end

  defp scan_file(path) do
    content = File.read!(path)
    lines = String.split(content, "\n")

    Enum.with_index(lines, 1)
    |> Enum.flat_map(fn {line, line_no} ->
      cond do
        # Definición local del módulo en el archivo del propio seam
        path_in_allowed?(path) ->
          []

        # Coincidencia por símbolo FollowupState (módulo) o followup_state (assign)
        contains_followup_ref?(line) ->
          [{path, line_no, line}]

        true ->
          []
      end
    end)
  end

  defp contains_followup_ref?(line) do
    String.contains?(line, "FollowupState") or
      String.contains?(line, "followup_state")
  end

  defp path_in_allowed?(path) do
    Enum.any?(@allowed_lib_paths, fn allowed ->
      String.contains?(path, allowed)
    end)
  end

  describe "ADR-010 §6 — no leak outside LiveView seam" do
    test "FollowupState is only referenced from the grounded_chat LiveView path under lib/" do
      references = find_lib_references()

      assert references == [],
             """
             ADR-010 §6 violated — `FollowupState` (or its assign `followup_state`)
             is referenced outside the LiveView seam.

             Offending locations:

             #{format_references(references)}

             How to fix:
               * Move the reference to `lib/alethea_web/live/grounded_chat/...`.
               * Or, if it is a legitimate LiveView seam (A2/B2/B3 integration),
                 add its absolute path to `@allowed_lib_paths` with a justifying
                 comment naming the issue and why it is part of the seam.

             Rules:
               * Never import/alias `FollowupState` from a `lib/alethea/...` (domain)
                 module — the state is exclusive to `lib/alethea_web/...`.
               * Never log a field of `FollowupState` via `Logger.metadata`,
                 `Accounts.log_action/1`, `Phoenix.PubSub.broadcast`, or any
                 other sink (DB/ETS/PubSub/audit).
             """
    end

    test "@allowed_lib_paths entries must be unique paths under lib/" do
      duplicates =
        @allowed_lib_paths
        |> Enum.group_by(& &1)
        |> Enum.filter(fn {_, list} -> length(list) > 1 end)
        |> Enum.map(fn {path, _list} -> path end)

      assert duplicates == [],
             "Duplicate entries in @allowed_lib_paths: #{inspect(duplicates)}"
    end
  end

  defp format_references([]), do: "  (none)"

  defp format_references(refs) do
    Enum.map_join(refs, "\n", fn {path, line, content} ->
      "  - #{path}:#{line}\n      > #{String.trim(content)}"
    end)
  end
end
