defmodule Alethea.Telegram.RiskSignal do
  @moduledoc """
  Bounded contract for conservative Telegram risk decisions.

  `build/4` accepts the exact `Alethea.Alerts.CrisisMonitor.detect/1` result
  and an optional detector outcome. A deterministic crisis match is always
  authoritative and cannot be downgraded; only this existing rules result can
  produce `:confirmed_crisis`. Optional `:escalated` signals remain
  non-authoritative and share the fixed uncertainty response intent.

  The result contains only bounded category, version, UTC classification time,
  deterministic rule-pattern metadata, and closed detector status/reason
  values. CrisisMonitor's trigger strings are regex sources, not matched
  patient text. Invalid metadata returns closed atoms and never echoes input.

  Production usage is disabled by default: this module does not invoke or
  configure a classifier. Upcoming inbound integration may explicitly supply
  controlled detector results, but must keep optional detector activation
  behind its own production-disabled configuration. This module persists
  nothing and does not send alerts or replies.
  """

  @enforce_keys [
    :category,
    :authority,
    :detector_version,
    :classified_at,
    :rule_matches,
    :rule_match_count,
    :rule_digest,
    :deterministic_severity,
    :detector_status,
    :response_intent
  ]
  defstruct [
    :category,
    :authority,
    :detector_version,
    :classified_at,
    :rule_matches,
    :rule_match_count,
    :rule_digest,
    :deterministic_severity,
    :detector_status,
    :unavailable_reason,
    :response_intent
  ]

  @type category :: :safe | :uncertain | :escalated | :confirmed_crisis
  @type t :: %__MODULE__{
          category: category(),
          authority: :deterministic_rule | :optional_signal | :none,
          detector_version: String.t(),
          classified_at: DateTime.t(),
          rule_matches: [String.t()],
          detector_status: :available | :unavailable,
          unavailable_reason: nil | :timeout | :disabled | :error,
          response_intent: :continue | :fixed_uncertainty | :existing_crisis_handling
        }

  @max_version_length 48
  @max_rule_matches 8
  @fixed_uncertainty "Gracias por compartirlo. Por precaución, no continuaré con preguntas en este momento. Contacta con tu profesional para recibir orientación"

  @spec build(term(), term(), term(), term()) ::
          {:ok, t()}
          | {:error,
             :invalid_metadata
             | :invalid_deterministic_result
             | :invalid_rule_matches
             | :invalid_detector_result}
  def build(deterministic_result, optional_result, detector_version, classified_at) do
    with {:ok, deterministic} <- normalize_deterministic(deterministic_result) do
      optional = normalize_optional(optional_result)
      version = normalize_version(detector_version)
      time = normalize_time(classified_at)
      {:ok, assemble(deterministic, optional, version, time)}
    end
  end

  @doc "Serializes only bounded, content-free fields for JSON persistence."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = signal) do
    %{
      "category" => Atom.to_string(signal.category),
      "authority" => Atom.to_string(signal.authority),
      "detector_version" => signal.detector_version,
      "classified_at" => DateTime.to_iso8601(signal.classified_at),
      "rule_matches" => signal.rule_matches,
      "rule_match_count" => signal.rule_match_count,
      "rule_digest" => signal.rule_digest,
      "deterministic_severity" => atom_or_nil(signal.deterministic_severity),
      "detector_status" => Atom.to_string(signal.detector_status),
      "unavailable_reason" => atom_or_nil(signal.unavailable_reason),
      "response_intent" => Atom.to_string(signal.response_intent)
    }
  end

  defp atom_or_nil(nil), do: nil
  defp atom_or_nil(value) when is_atom(value), do: Atom.to_string(value)

  @doc "Returns the fixed response text for the uncertainty intent; never generates patient-specific content."
  @spec uncertainty_copy() :: String.t()
  def uncertainty_copy, do: @fixed_uncertainty

  defp normalize_version(version)
       when is_binary(version) and byte_size(version) in 1..@max_version_length,
       do: version

  defp normalize_version(_), do: "unknown"

  defp normalize_time(%DateTime{} = time), do: DateTime.shift_zone!(time, "Etc/UTC")
  defp normalize_time(_), do: DateTime.utc_now()

  defp normalize_deterministic(:safe), do: {:ok, :safe}

  defp normalize_deterministic({:crisis, severity, matches})
       when severity in [:immediate, :high, :low] and is_list(matches),
       do: {:ok, {:crisis, severity, matches}}

  defp normalize_deterministic(_), do: {:error, :invalid_deterministic_result}

  defp normalize_optional({:available, category})
       when category in [:safe, :uncertain, :escalated],
       do: {:available, category}

  defp normalize_optional({:unavailable, reason}) when reason in [:timeout, :disabled, :error],
    do: {:unavailable, reason}

  defp normalize_optional(_), do: {:unavailable, :error}

  defp assemble({:crisis, severity, matches}, optional, version, time) do
    %__MODULE__{
      category: :confirmed_crisis,
      authority: :deterministic_rule,
      detector_version: version,
      classified_at: time,
      rule_matches: rule_ids(matches),
      rule_match_count: length(matches),
      rule_digest: digest(matches),
      deterministic_severity: severity,
      detector_status: detector_status(optional),
      unavailable_reason: unavailable_reason(optional),
      response_intent: :existing_crisis_handling
    }
  end

  defp assemble(:safe, optional, version, time) do
    {category, authority, response} = optional_decision(optional)

    %__MODULE__{
      category: category,
      authority: authority,
      detector_version: version,
      classified_at: time,
      rule_matches: [],
      rule_match_count: 0,
      rule_digest: digest([]),
      deterministic_severity: nil,
      detector_status: detector_status(optional),
      unavailable_reason: unavailable_reason(optional),
      response_intent: response
    }
  end

  defp optional_decision({:available, :safe}), do: {:safe, :none, :continue}

  defp optional_decision({:available, :uncertain}),
    do: {:uncertain, :optional_signal, :fixed_uncertainty}

  defp optional_decision({:available, :escalated}),
    do: {:escalated, :optional_signal, :fixed_uncertainty}

  defp optional_decision({:unavailable, _}), do: {:safe, :none, :continue}

  defp rule_ids(matches), do: matches |> Enum.take(@max_rule_matches) |> Enum.map(&hash/1)
  defp digest(matches), do: matches |> Enum.map(&hash/1) |> Enum.join(":") |> hash()

  defp hash(value),
    do:
      :crypto.hash(:sha256, IO.iodata_to_binary(value))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 24)

  defp detector_status({status, _}), do: status
  defp unavailable_reason({:unavailable, reason}), do: reason
  defp unavailable_reason(_), do: nil
end
