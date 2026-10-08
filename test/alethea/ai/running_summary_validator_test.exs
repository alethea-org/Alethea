defmodule Alethea.AI.RunningSummaryValidatorTest do
  use ExUnit.Case, async: false

  alias Alethea.Alerts.CrisisCopy
  alias Alethea.AI.RunningSummaryValidator

  @facts "Hechos que la persona relató:"
  @questions "Preguntas que Alethea hizo:"

  @valid """
  #{@facts}
  - Discutió con su jefe el martes.

  #{@questions}
  - ¿Qué pasó después de la reunión?
  """

  @crisis_copy "Si estás en peligro inmediato, llama al número de emergencias de tu zona.\nNo estás sola en esto, hay personas que quieren ayudarte.\nHola."

  describe "validate/2 format" do
    test "accepts a well-formed summary" do
      assert :ok = RunningSummaryValidator.validate(@valid, @crisis_copy)
    end

    test "accepts a summary with empty sections" do
      assert :ok = RunningSummaryValidator.validate("#{@facts}\n\n#{@questions}\n", @crisis_copy)
    end

    test "rejects text over the 1200 character cap" do
      long = String.duplicate("a", 1200)
      text = "#{@facts}\n- #{long}\n#{@questions}\n- ¿Algo?"

      assert {:error, :invalid_summary} = RunningSummaryValidator.validate(text, @crisis_copy)
    end

    test "accepts text exactly at the cap" do
      filler = String.duplicate("a", 1200 - String.length("#{@facts}\n- \n#{@questions}"))
      text = "#{@facts}\n- #{filler}\n#{@questions}"
      assert String.length(text) == 1200

      assert :ok = RunningSummaryValidator.validate(text, @crisis_copy)
    end

    test "rejects a missing facts heading" do
      text = "- Un hecho.\n#{@questions}\n- ¿Algo?"
      assert {:error, :invalid_summary} = RunningSummaryValidator.validate(text, @crisis_copy)
    end

    test "rejects a missing questions heading" do
      text = "#{@facts}\n- Un hecho."
      assert {:error, :invalid_summary} = RunningSummaryValidator.validate(text, @crisis_copy)
    end

    test "rejects a third heading" do
      text = "#{@facts}\n- Un hecho.\n#{@questions}\n- ¿Algo?\nConclusiones:\n- Nada."
      assert {:error, :invalid_summary} = RunningSummaryValidator.validate(text, @crisis_copy)
    end

    test "rejects reordered headings" do
      text = "#{@questions}\n- ¿Algo?\n#{@facts}\n- Un hecho."
      assert {:error, :invalid_summary} = RunningSummaryValidator.validate(text, @crisis_copy)
    end

    test "rejects a duplicated heading" do
      text = "#{@facts}\n- Un hecho.\n#{@facts}\n#{@questions}"
      assert {:error, :invalid_summary} = RunningSummaryValidator.validate(text, @crisis_copy)
    end

    test "rejects a non-bullet line" do
      text = "#{@facts}\nTexto suelto sin viñeta.\n#{@questions}\n- ¿Algo?"
      assert {:error, :invalid_summary} = RunningSummaryValidator.validate(text, @crisis_copy)
    end

    test "rejects non-binary input" do
      assert {:error, :invalid_summary} = RunningSummaryValidator.validate(nil, @crisis_copy)
    end
  end

  describe "validate/2 output guard" do
    test "rejects text blocked by JournalingOutputGuard" do
      text = "#{@facts}\n- Tiene un diagnóstico de depresión.\n#{@questions}\n- ¿Algo?"
      assert {:blocked, _} = Alethea.AI.JournalingOutputGuard.check(text)
      assert {:error, :invalid_summary} = RunningSummaryValidator.validate(text, @crisis_copy)
    end
  end

  describe "validate/2 crisis copy" do
    setup do
      previous = Application.fetch_env(:alethea, :crisis_support_message)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:alethea, :crisis_support_message, value)
          :error -> Application.delete_env(:alethea, :crisis_support_message)
        end
      end)

      :ok
    end

    defp summary_with(line), do: "#{@facts}\n- #{line}\n#{@questions}\n- ¿Algo más?"

    test "rejects the professional's crisis message" do
      copy = CrisisCopy.reply_text(%{professional: %{crisis_message: @crisis_copy}})

      text =
        summary_with("Si estás en peligro inmediato, llama al número de emergencias de tu zona.")

      assert {:error, :invalid_summary} = RunningSummaryValidator.validate(text, copy)
    end

    test "rejects the application-config crisis message" do
      Application.put_env(
        :alethea,
        :crisis_support_message,
        "Texto de apoyo desde configuración larga."
      )

      copy = CrisisCopy.reply_text(%{professional: %{crisis_message: nil}})
      text = summary_with("Texto de apoyo desde configuración larga.")

      assert {:error, :invalid_summary} = RunningSummaryValidator.validate(text, copy)
    end

    test "rejects the system default crisis message" do
      Application.delete_env(:alethea, :crisis_support_message)
      copy = CrisisCopy.reply_text(%{professional: %{crisis_message: nil}})
      text = summary_with(CrisisCopy.default_support_message())

      assert {:error, :invalid_summary} = RunningSummaryValidator.validate(text, copy)
    end

    test "matches regardless of case, accents and whitespace" do
      text =
        summary_with(
          "SI ESTAS EN PELIGRO   inmediato, llama al numero de emergencias de tu zona."
        )

      assert {:error, :invalid_summary} = RunningSummaryValidator.validate(text, @crisis_copy)
    end

    test "rejects a single copied line of at least 20 characters" do
      text = summary_with("No estás sola en esto, hay personas que quieren ayudarte.")

      assert {:error, :invalid_summary} = RunningSummaryValidator.validate(text, @crisis_copy)
    end

    test "does not reject an empty line or a copy line shorter than 20 characters" do
      text = "#{@facts}\n- Hola.\n\n#{@questions}\n- ¿Algo más?"

      assert :ok =
               RunningSummaryValidator.validate(text, "Hola.\n\n#{String.duplicate(" ", 3)}\n")
    end

    test "skips a blank crisis copy" do
      assert :ok = RunningSummaryValidator.validate(@valid, "")
      assert :ok = RunningSummaryValidator.validate(@valid, "   \n  ")
      assert :ok = RunningSummaryValidator.validate(@valid, nil)
    end
  end
end
