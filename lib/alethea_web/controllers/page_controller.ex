defmodule AletheaWeb.PageController do
  use AletheaWeb, :controller

  alias Alethea.Waitlist

  def home(conn, _params) do
    if conn.assigns[:current_professional] do
      redirect(conn, to: "/dashboard")
    else
      render(conn, :home,
        waitlist_form: Phoenix.Component.to_form(Waitlist.change_entry(), as: :waitlist),
        show_login?: not Alethea.Accounts.AdmissionPolicy.restricted?()
      )
    end
  end
end
