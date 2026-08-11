defmodule Alethea.Operator.TaskRuntime do
  @moduledoc false

  @applications [:ecto_sql, :cloak, :phoenix_pubsub, :pbkdf2_elixir]

  @spec with_services((-> result)) :: result when result: var
  def with_services(fun) when is_function(fun, 0) do
    Enum.each(@applications, fn application ->
      {:ok, _started} = Application.ensure_all_started(application)
    end)

    children =
      []
      |> add_unless_started(Alethea.Encryption.Vault, Alethea.Encryption.Vault)
      |> add_unless_started(Alethea.Repo, Alethea.Repo)
      |> add_unless_started(Alethea.PubSub, {Phoenix.PubSub, name: Alethea.PubSub})

    case children do
      [] ->
        fun.()

      children ->
        {:ok, supervisor} = Supervisor.start_link(children, strategy: :one_for_one)

        try do
          fun.()
        after
          Supervisor.stop(supervisor)
        end
    end
  end

  defp add_unless_started(children, name, child_spec) do
    if Process.whereis(name), do: children, else: children ++ [child_spec]
  end
end
