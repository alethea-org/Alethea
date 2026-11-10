defmodule Alethea.Alerts.CrisisCopyTest do
  use ExUnit.Case, async: false

  alias Alethea.Alerts.CrisisCopy

  @default "Entiendo que estás pasando por algo muy difícil. Lo que sientes importa."

  setup do
    previous = Application.fetch_env(:alethea, :crisis_support_message)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:alethea, :crisis_support_message, value)
        :error -> Application.delete_env(:alethea, :crisis_support_message)
      end
    end)

    Application.delete_env(:alethea, :crisis_support_message)
    :ok
  end

  defp patient(crisis_message), do: %{professional: %{crisis_message: crisis_message}}

  describe "reply_text/1" do
    test "returns the professional's crisis_message when set" do
      Application.put_env(:alethea, :crisis_support_message, "from config")

      assert CrisisCopy.reply_text(patient("Llama a tu psicologa.")) == "Llama a tu psicologa."
    end

    test "passes an empty-string crisis_message through (|| semantics)" do
      Application.put_env(:alethea, :crisis_support_message, "from config")

      assert CrisisCopy.reply_text(patient("")) == ""
    end

    test "falls back to the :crisis_support_message app env when crisis_message is nil" do
      Application.put_env(:alethea, :crisis_support_message, "from config")

      assert CrisisCopy.reply_text(patient(nil)) == "from config"
    end

    test "falls back to the default text when nil and no app env" do
      assert CrisisCopy.reply_text(patient(nil)) == @default
    end
  end

  describe "configured :crisis_support_message (config/runtime.exs)" do
    test "points patients to the Argentine nationwide suicide-prevention line" do
      message =
        "config/runtime.exs"
        |> Config.Reader.read!(env: :test, target: :host)
        |> get_in([:alethea, :crisis_support_message])

      assert message =~ "0800 345 1435"
      assert message =~ "911"

      for chilean <- ["Salud Responde", "600 360 7777", "ACHS", "SAMU", "131", "🇨🇱"] do
        refute message =~ chilean
      end
    end
  end

  describe "default_support_message/0" do
    test "returns the system default text" do
      assert CrisisCopy.default_support_message() == @default
    end
  end
end
