defmodule Alethea.EmotionAnalyzerConfigTest do
  use ExUnit.Case, async: false

  alias Alethea.AI.EmotionAnalyzer

  test "development runtime reads sidecar configuration after loading dotenv" do
    runtime_path = Path.expand("config/runtime.exs")

    dotenv_dir =
      Path.join(System.tmp_dir!(), "alethea-runtime-config-#{System.unique_integer([:positive])}")

    sidecar_url = "http://emotion-sidecar.internal:8080"
    original_url = System.get_env("EMOTION_SIDECAR_URL")

    File.mkdir_p!(dotenv_dir)
    File.write!(Path.join(dotenv_dir, ".env"), "EMOTION_SIDECAR_URL=#{sidecar_url}\n")
    System.delete_env("EMOTION_SIDECAR_URL")

    on_exit(fn ->
      File.rm_rf!(dotenv_dir)

      if original_url,
        do: System.put_env("EMOTION_SIDECAR_URL", original_url),
        else: System.delete_env("EMOTION_SIDECAR_URL")
    end)

    config = File.cd!(dotenv_dir, fn -> Config.Reader.read!(runtime_path, env: :dev) end)
    analyzer_config = config |> Keyword.fetch!(:alethea) |> Keyword.fetch!(EmotionAnalyzer)

    assert analyzer_config[:base_url] == sidecar_url
    assert analyzer_config[:max_batch_size] == 32
    assert analyzer_config[:max_text_bytes] == 4096
  end
end
