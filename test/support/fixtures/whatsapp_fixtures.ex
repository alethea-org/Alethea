defmodule AletheaWeb.WhatsappFixtures do
  @moduledoc """
  Helper functions para cargar fixtures de WhatsApp y generar signatures.
  """

  @app_secret Application.compile_env(:alethea, :whatsapp)[:app_secret] || "test_secret"

  @doc """
  Carga un fixture de WhatsApp desde el directorio test/fixtures/whatsapp/.

  ## Ejemplos

      ie> text_message()
      {:ok, %{"entry" => [...]}}

      ie> image_message()
      {:ok, %{"entry" => [...]}}
  """
  def text_message, do: load_fixture("text_message.json")
  def image_message, do: load_fixture("image_message.json")
  def audio_message, do: load_fixture("audio_message.json")
  def video_message, do: load_fixture("video_message.json")
  def document_message, do: load_fixture("document_message.json")
  def location_message, do: load_fixture("location_message.json")
  def contacts_message, do: load_fixture("contacts_message.json")
  def status_update, do: load_fixture("status_update.json")

  defp load_fixture(filename) do
    # Use __DIR__ para obtener la ruta del archivo actual y subir al root
    fixture_dir = Path.join([__DIR__, "..", "..", "fixtures", "whatsapp"])
    path = Path.join(fixture_dir, filename)

    case File.read(path) do
      {:ok, contents} -> Jason.decode(contents)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Genera una firma HMAC-SHA256 válida para un body dado.

  ## Ejemplos

      ie> body = Jason.encode!(%{"key" => "value"})
      ie> valid_signature(body)
      "sha256=..."
  """
  def valid_signature(body) when is_binary(body) do
    signature =
      :crypto.mac(:hmac, :sha256, @app_secret, body)
      |> Base.encode16(case: :lower)

    "sha256=#{signature}"
  end

  @doc """
  Genera una firma inválida (firma incorrecta).
  """
  def invalid_signature(_body) do
    "sha256=invalid_signature_hash"
  end

  @doc """
  Genera una firma con clave secreta diferente (falsa).
  """
  def wrong_secret_signature(body) when is_binary(body) do
    wrong_secret = "wrong_secret_for_testing"
    signature = :crypto.mac(:hmac, :sha256, wrong_secret, body) |> Base.encode16(case: :lower)
    "sha256=#{signature}"
  end
end