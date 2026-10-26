defmodule AletheaWeb.RegistrationController do
  use AletheaWeb, :controller

  alias Alethea.Accounts
  alias Alethea.Accounts.AdmissionPolicy
  alias Alethea.Accounts.Professional

  def new(conn, _params) do
    changeset = Professional.changeset(%Professional{}, %{})
    render(conn, :new, changeset: changeset)
  end

  def create(conn, %{"professional" => professional_params}) do
    email = professional_params["email"] || professional_params[:email]

    if AdmissionPolicy.restricted?() and not AdmissionPolicy.allowed_email?(email) do
      changeset =
        %Professional{}
        |> Professional.changeset(professional_params)
        |> Ecto.Changeset.add_error(:email, "no autorizado")

      render(conn, :new, changeset: changeset)
    else
      case Accounts.create_professional(professional_params) do
        {:ok, _professional} ->
          conn
          |> put_flash(:info, "Cuenta creada con éxito. Ahora podés iniciar sesión.")
          |> redirect(to: "/login")

        {:error, %Ecto.Changeset{} = changeset} ->
          render(conn, :new, changeset: changeset)
      end
    end
  end
end
