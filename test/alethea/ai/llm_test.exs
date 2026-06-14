defmodule Alethea.AI.LLMTest do
  @moduledoc """
  Behaviour contract tests for `Alethea.AI.LLM` and its Fake adapter.

  Per `openspec/sdd/bootstrap-alethea-v2/specs/ai/spec.md`:

  - The behaviour declares `chat/2` and `generate/2`.
  - `behaviour_info(:callbacks)` returns the expected list.
  - A module that `use Alethea.AI.LLM` without defining both callbacks
    gets a compiler warning.
  - The Fake adapter returns deterministic, contract-compliant tuples
    for both callbacks.
  """

  use ExUnit.Case, async: true

  alias Alethea.AI.LLM

  describe "behaviour contract" do
    test "behaviour_info/1 lists chat/2 and generate/2" do
      callbacks = LLM.behaviour_info(:callbacks)
      assert {:chat, 2} in callbacks
      assert {:generate, 2} in callbacks
    end

    test "use Alethea.AI.LLM without chat/2 emits a compiler warning" do
      code = """
      defmodule Alethea.AI.LLMTest.WarningProbe do
        use Alethea.AI.LLM
        # NOTE: chat/2 is intentionally missing
        def generate(_prompt, _opts), do: {:ok, ""}
      end
      """

      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        Code.compile_string(code)
      end)
      |> tap(&send(self(), {:stderr, &1}))
      |> then(fn _ -> :ok end)

      assert_received {:stderr, stderr}
      assert stderr =~ "chat"
    end

    test "use Alethea.AI.LLM without generate/2 emits a compiler warning" do
      code = """
      defmodule Alethea.AI.LLMTest.WarningProbe2 do
        use Alethea.AI.LLM
        # NOTE: generate/2 is intentionally missing
        def chat(_messages, _opts), do: {:ok, %{content: "", usage: nil, model: "x"}}
      end
      """

      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        Code.compile_string(code)
      end)
      |> tap(&send(self(), {:stderr, &1}))
      |> then(fn _ -> :ok end)

      assert_received {:stderr, stderr}
      assert stderr =~ "generate"
    end
  end

  describe "Alethea.AI.LLM.Fake adapter" do
    alias Alethea.AI.LLM.Fake

    test "chat/2 returns a contract-compliant response map" do
      messages = [%{role: :user, content: "hola"}]
      assert {:ok, response} = Fake.chat(messages, [])

      assert response.content == "fake-response"
      assert response.usage == nil
      assert response.model == "fake-llm"
    end

    test "chat/2 ignores message contents (deterministic)" do
      assert {:ok, r1} = Fake.chat([%{role: :user, content: "uno"}], [])
      assert {:ok, r2} = Fake.chat([%{role: :user, content: "dos"}], [])
      assert r1.content == r2.content
      assert r1.model == r2.model
    end

    test "chat/2 accepts a messages list and a keyword list" do
      # Triangulation: passing multiple messages must not crash or
      # return an error tuple.
      messages = [
        %{role: :system, content: "sos Alethea"},
        %{role: :user, content: "como estoy?"}
      ]

      assert {:ok, %{content: content}} = Fake.chat(messages, temperature: 0.7)
      assert is_binary(content)
      assert content != ""
    end

    test "generate/2 returns a deterministic string" do
      assert {:ok, text} = Fake.generate("un prompt cualquiera", [])
      assert text == "fake-completion"
    end

    test "generate/2 ignores prompt contents (deterministic)" do
      assert {:ok, a} = Fake.generate("uno", [])
      assert {:ok, b} = Fake.generate("dos", [])
      assert a == b
    end
  end
end
