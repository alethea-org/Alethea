defmodule Alethea.AI.DiagnosisTest do
  use ExUnit.Case, async: true

  alias Alethea.AI.Diagnosis

  describe "PHI redaction in inspect output" do
    test "changeset inspect redacts plaintext ai_response and extracted_emotions" do
      sentinel_reply = "PLAINTEXT_CLINICAL_REPLY_SENTINEL"
      sentinel_emotion = "PLAINTEXT_EMOTION_SENTINEL"

      changeset =
        Diagnosis.changeset(%Diagnosis{}, %{
          model_version: "phi-4-mini",
          ai_response: sentinel_reply,
          extracted_emotions: %{note: sentinel_emotion},
          message_id: Ecto.UUID.generate()
        })

      rendered = inspect(changeset)

      refute rendered =~ sentinel_reply
      refute rendered =~ sentinel_emotion
      assert rendered =~ "**redacted**"
    end

    test "bare struct inspect does not leak ai_response or extracted_emotions" do
      diagnosis = %Diagnosis{
        model_version: "phi-4-mini",
        ai_response: "PLAINTEXT_STRUCT_SENTINEL",
        extracted_emotions: %{note: "PLAINTEXT_STRUCT_EMOTION"}
      }

      rendered = inspect(diagnosis)

      refute rendered =~ "PLAINTEXT_STRUCT_SENTINEL"
      refute rendered =~ "PLAINTEXT_STRUCT_EMOTION"
    end
  end
end
