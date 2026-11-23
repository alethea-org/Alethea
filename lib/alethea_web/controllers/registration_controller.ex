defmodule AletheaWeb.RegistrationController do
  use AletheaWeb, :controller

  alias Alethea.Accounts
  alias Alethea.Accounts.AdmissionPolicy
  alias Alethea.Accounts.Professional

  # While admission is restricted, registration is closed to the public:
  # visitors go to the launch waitlist. The operator shares
  # `/register?invitacion=1` with allowed people; the allowlist is still
  # enforced on submit, so the link grants nothing by itself.
  def new(conn, params) do
    if AdmissionPolicy.restricted?() and params["invitacion"] != "1" do
      redirect(conn, to: "/#lista-de-espera")
    else
      changeset = Professional.changeset(%Professional{}, %{})
      render(conn, :new, changeset: changeset)
    end
  end

  def create(conn, %{"professional" => professional_params}) do
    email = professional_params["email"] || professional_params[:email]

    if not AdmissionPolicy.allowed_email?(email) do
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
