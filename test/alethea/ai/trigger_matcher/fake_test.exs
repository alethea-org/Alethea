defmodule Alethea.AI.TriggerMatcher.FakeTest do
  use ExUnit.Case, async: true

  alias Alethea.AI.TriggerMatcher.Fake

  test "returns one probability per candidate, keyed by trigger id" do
    a = Ecto.UUID.generate()
    b = Ecto.UUID.generate()

    assert {:ok, probabilities} =
             Fake.match("Hoy discutí con mi madre por teléfono", [
               %{id: a, condition: "discusión con su madre"},
               %{id: b, condition: "insomnio persistente"}
             ])

    assert Map.keys(probabilities) |> Enum.sort() == Enum.sort([a, b])
    assert probabilities[b] == 0.0
    assert probabilities[a] > 0.0 and probabilities[a] <= 1.0
  end

  test "is deterministic and case-insensitive" do
    id = Ecto.UUID.generate()
    candidates = [%{id: id, condition: "Madre"}]

    assert Fake.match("MI MADRE", candidates) == {:ok, %{id => 1.0}}
    assert Fake.match("mi madre", candidates) == {:ok, %{id => 1.0}}
  end

  test "an empty candidate list yields no probabilities" do
    assert Fake.match("texto", []) == {:ok, %{}}
  end
end
