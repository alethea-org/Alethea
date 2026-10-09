defmodule Alethea.Telegram.TopicExploration do
  @moduledoc """
  Follows the patient's latest topic and enforces the three-question
  stretch limit, then closes gently (#393).

  This module is pure: no Repo access, no AI worker call. It has two
  responsibilities, both driven by the model's leading marker:

    * `parse_marker/1` tolerates case, spacing, placement, and
      truncation when reading the `<<NUEVO>>`/`<<SIGUE>>` marker the
      model is instructed to prefix its reply with (design §1), and
      strips any marker-shaped text from the reply the patient sees.
    * `mode/1` and `enforce/4` implement the question-limit and
      closing/acknowledgement decision table (design §3): at most 3
      questions per stretch, then a soft closing invitation, then a
      brief acknowledgement with no further question.

  Nothing in production code calls this module yet (#393 S2) — the
  worker wiring (`JournalingReply.generate_burst/2`,
  `TelegramBurstReplyWorker`) is S3.
  """

  alias Alethea.AI.JournalingPrompt
  alias Alethea.Telegram.JournalingFallback

  @typedoc "The stretch state read from the snapshot (`Alethea.Clinical.exploration_state/3`)."
  @type state :: %{questions: 0..3, closing_invitation_sent: boolean()}

  @typedoc "The minimal shape `enforce/4` reads and extends with `:exploration`."
  @type reply_result :: %{required(:response) => String.t(), optional(atom()) => term()}

  # Design §1: the literal marker strings live on `JournalingPrompt`
  # (the module that renders them) and are read here through
  # `markers/0`, so they exist in one place only. The bare words
  # (without `<<`/`>>`) feed the leading-marker alternation below.
  @markers JournalingPrompt.markers()
  @new_word String.replace(@markers.new, ~r/[<>]/, "")
  @same_word String.replace(@markers.same, ~r/[<>]/, "")

  @leading_marker_regex ~r/\A\s*<<\s*(#{@new_word}|#{@same_word})\s*>>/iu
  @strip_markers_regex ~r/<<[^<>\n]{0,20}>>/u
  @unclosed_leading_regex ~r/\A\s*<<[A-Za-z]*\s*/u

  @model_version "journaling-fallback"

  @doc """
  Reads the leading marker and strips every marker-shaped token from
  `text` (design §1).

  Returns `{new_situation, stripped_text}`. `new_situation` is `true`
  only when the text *starts* with `<<NUEVO>>` (tolerating case and
  internal spacing); a missing, malformed, or merely misplaced marker
  is treated as `<<SIGUE>>` (`new_situation = false`), per Requirement
  "Marker Signal". `stripped_text` never contains `<<…>>` — a
  patient-facing reply never legitimately contains that syntax — and a
  truncated, unclosed leading fragment left by generation is removed
  too. Normalizes with `String.trim/1`.

  `stripped_text` may be `""` when the reply was marker-only; the
  caller (`JournalingReply`, #393 S3) is the one that turns that into
  `{:error, :empty_response}`.
  """
  @spec parse_marker(String.t()) :: {boolean(), String.t()}
  def parse_marker(text) when is_binary(text) do
    new_situation = leading_new_situation?(text)

    stripped =
      text
      |> strip_markers()
      |> strip_unclosed_leading_fragment()
      |> String.trim()

    {new_situation, stripped}
  end

  defp leading_new_situation?(text) do
    case Regex.run(@leading_marker_regex, text) do
      [_whole, captured] -> String.upcase(captured) == @new_word
      nil -> false
    end
  end

  defp strip_markers(text), do: Regex.replace(@strip_markers_regex, text, "")

  defp strip_unclosed_leading_fragment(text),
    do: Regex.replace(@unclosed_leading_regex, text, "")

  @doc """
  `:closing` once the stretch has reached the question limit, `:open`
  otherwise (design §3). Drives `exploration_mode` in the AI worker
  request (#393 S3).
  """
  @spec mode(state()) :: :open | :closing
  def mode(%{questions: questions}) when questions >= 3, do: :closing
  def mode(%{questions: _questions}), do: :open

  @doc """
  Enforces the three-question stretch limit and closing/acknowledgement
  copy (design §3's four-row table). `new_situation` is the boolean
  `parse_marker/1` returned for this reply; `inbound_id` selects stable
  closing/acknowledgement copy the same way
  `JournalingFallback.for_inbound/1` does.

  Returns `reply` with an added `:exploration` key —
  `%{exploration_questions:, closing_invitation_sent:, new_situation:}`
  — meant to be persisted via `Alethea.Clinical.save_telegram_reply/6`
  (#393 S3). When a model question is replaced by fixed copy,
  `:response` and `:model_version` are swapped too; any `:guardrail`
  already on `reply` is left untouched either way.
  """
  @spec enforce(reply_result(), state(), boolean(), binary()) :: reply_result()
  def enforce(reply, _state, true = new_situation, _inbound_id) do
    finish(reply, bool_to_count(question?(reply)), false, new_situation)
  end

  def enforce(reply, %{questions: questions, closing_invitation_sent: sent}, false, _inbound_id)
      when questions < 3 do
    new_count = questions + bool_to_count(question?(reply))
    finish(reply, new_count, sent, false)
  end

  def enforce(reply, %{questions: 3, closing_invitation_sent: false}, false, inbound_id) do
    reply
    |> maybe_substitute(question?(reply), fn ->
      JournalingFallback.closing_for_inbound(inbound_id)
    end)
    |> finish(3, true, false)
  end

  def enforce(reply, %{questions: 3, closing_invitation_sent: true}, false, inbound_id) do
    reply
    |> maybe_substitute(question?(reply), fn ->
      JournalingFallback.acknowledgement_for_inbound(inbound_id)
    end)
    |> finish(3, true, false)
  end

  defp question?(%{response: text}) when is_binary(text), do: String.contains?(text, ["?", "¿"])

  defp bool_to_count(true), do: 1
  defp bool_to_count(false), do: 0

  defp maybe_substitute(reply, true, fallback_fun) do
    reply
    |> Map.put(:response, fallback_fun.())
    |> Map.put(:model_version, @model_version)
  end

  defp maybe_substitute(reply, false, _fallback_fun), do: reply

  defp finish(reply, questions, closing_invitation_sent, new_situation) do
    Map.put(reply, :exploration, %{
      exploration_questions: questions,
      closing_invitation_sent: closing_invitation_sent,
      new_situation: new_situation
    })
  end
end
