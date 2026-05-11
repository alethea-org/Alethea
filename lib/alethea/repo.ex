defmodule Alethea.Repo do
  use Ecto.Repo,
    otp_app: :alethea,
    adapter: Ecto.Adapters.Postgres
end
