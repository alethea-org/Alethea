defmodule Alethea.Repo do
  use Ecto.Repo,
    otp_app: :alethea,
    adapter: Ecto.Adapters.Postgres

  def init(_type, config) do
    {:ok, Keyword.put(config, :types, Alethea.PostgrexTypes)}
  end
end
