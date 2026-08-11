defmodule Alethea.RuntimeEnvTest do
  use ExUnit.Case, async: false

  alias Alethea.RuntimeEnv

  setup do
    keys = ["DOTENV_EXISTING", "DOTENV_NEW", "DOTENV_QUOTED"]
    original = Map.new(keys, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(original, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  test "load_dotenv/1 ignores a missing file" do
    path = Path.join(System.tmp_dir!(), "alethea-missing-#{System.unique_integer([:positive])}")

    assert RuntimeEnv.load_dotenv(path) == :ok
  end

  test "load_dotenv/1 fills missing values without overwriting the process environment" do
    System.put_env("DOTENV_EXISTING", "process-value")
    System.delete_env("DOTENV_NEW")

    with_dotenv("DOTENV_EXISTING=file-value\nDOTENV_NEW=new-value\n", fn path ->
      assert RuntimeEnv.load_dotenv(path) == :ok
    end)

    assert System.get_env("DOTENV_EXISTING") == "process-value"
    assert System.get_env("DOTENV_NEW") == "new-value"
  end

  test "load_dotenv/1 accepts export, comments, and quoted values" do
    System.delete_env("DOTENV_QUOTED")

    with_dotenv("# ignored\nexport DOTENV_QUOTED='quoted value'\ninvalid line\n", fn path ->
      assert RuntimeEnv.load_dotenv(path) == :ok
    end)

    assert System.get_env("DOTENV_QUOTED") == "quoted value"
  end

  test "load_dotenv/1 never logs loaded keys or values" do
    System.delete_env("DOTENV_NEW")

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        with_dotenv("DOTENV_NEW=private-value\n", &RuntimeEnv.load_dotenv/1)
      end)

    assert output == ""
  end

  defp with_dotenv(contents, callback) do
    path = Path.join(System.tmp_dir!(), "alethea-dotenv-#{System.unique_integer([:positive])}")
    File.write!(path, contents)

    try do
      callback.(path)
    after
      File.rm(path)
    end
  end
end
