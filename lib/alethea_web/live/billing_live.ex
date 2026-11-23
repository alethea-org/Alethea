defmodule AletheaWeb.BillingLive do
  @moduledoc """
  The professional's subscription page (`/billing`).

  Reachable without paid access, so a professional who has not paid (or
  whose subscription lapsed) can subscribe, see their status, or log out.

  Checkout runs client-side in Paddle.js overlay (the `PaddleCheckout`
  hook). Completing it only switches this page to a "processing" state:
  access unlocks when `Alethea.Billing` applies the verified webhook and
  broadcasts on the professional's billing topic.
  """
  use AletheaWeb, :live_view

  alias Alethea.Billing

  @impl true
  def mount(_params, _session, socket) do
    professional = socket.assigns.current_professional

    if connected?(socket), do: Billing.subscribe(professional.id)

    {:ok,
     socket
     |> assign(:page_title, "Suscripción")
     |> assign(:processing, false)
     |> assign_billing()}
  end

  @impl true
  def handle_event("checkout_completed", _params, socket) do
    {:noreply, assign(socket, :processing, true)}
  end

  def handle_event("checkout_failed", _params, socket) do
    {:noreply,
     put_flash(socket, :error, "No pudimos abrir el pago. Probá de nuevo en unos minutos.")}
  end

  def handle_event("open_portal", _params, socket) do
    case Billing.customer_portal_url(socket.assigns.current_professional) do
      {:ok, url} ->
        {:noreply, redirect(socket, external: url)}

      {:error, _reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "No pudimos abrir el portal de pagos. Probá de nuevo en unos minutos."
         )}
    end
  end

  @impl true
  def handle_info({:billing_updated, _professional_id}, socket) do
    was_entitled = socket.assigns.entitled
    socket = assign_billing(socket)

    if socket.assigns.entitled and not was_entitled do
      {:noreply,
       socket
       |> put_flash(:info, "Tu suscripción está activa.")
       |> push_navigate(to: ~p"/dashboard")}
    else
      {:noreply, socket}
    end
  end

  defp assign_billing(socket) do
    professional = socket.assigns.current_professional
    enabled = Billing.enabled?()

    socket
    |> assign(:billing_enabled, enabled)
    |> assign(:subscription, Billing.current_subscription(professional))
    |> assign(:entitled, Billing.entitled?(professional))
    |> assign(:checkout, if(enabled, do: Billing.checkout_config(professional)))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="pt ptd-wrap" id="billing">
      <div class="ptd-head">
        <div>
          <p class="pt-eyebrow">Suscripción</p>
          <h1 class="pt-h1">Tu plan</h1>
        </div>
      </div>

      <%= cond do %>
        <% not @billing_enabled -> %>
          <section id="billing-disabled" class="billing-card">
            <p>La facturación no está activa en este entorno. Tenés acceso completo.</p>
            <.link navigate={~p"/dashboard"} class="button-primary button-primary--sm">
              Ir al panel
            </.link>
          </section>
        <% @processing and not @entitled -> %>
          <section id="billing-processing" class="billing-card" role="status" aria-live="polite">
            <h2 class="billing-card__title">Estamos procesando tu pago</h2>
            <p>
              Paddle nos está confirmando el pago. Esta página se actualiza sola apenas llegue la confirmación; no hace falta que pagues de nuevo.
            </p>
          </section>
        <% true -> %>
          <section :if={@subscription} id="billing-status" class="billing-card">
            <h2 class="billing-card__title">Estado: {status_label(@subscription)}</h2>
            <p :if={date = period_date(@subscription)} id="billing-period">
              {period_label(@subscription)}: {date}
            </p>
            <div class="billing-card__actions">
              <.link
                :if={@entitled}
                navigate={~p"/dashboard"}
                class="button-primary button-primary--sm"
              >
                Ir al panel
              </.link>
              <button
                :if={@subscription.paddle_customer_id}
                id="billing-portal"
                type="button"
                phx-click="open_portal"
                class="button-secondary button-secondary--sm"
              >
                Gestionar pago y facturas
              </button>
            </div>
          </section>

          <section
            :if={not @entitled}
            id="billing-plans"
            phx-hook="PaddleCheckout"
            data-config={Jason.encode!(@checkout)}
          >
            <p class="billing-intro">
              Para usar el espacio clínico necesitás una suscripción activa. Tus pacientes y tu historial se conservan.
            </p>
            <div class="billing-plans">
              <article
                :for={price_id <- @checkout.price_ids}
                id={"plan-#{price_id}"}
                class="billing-card billing-plan"
                data-price-id={price_id}
              >
                <h2 class="billing-card__title" data-price-name>Plan</h2>
                <p class="billing-plan__price" data-price-total>—</p>
                <p class="billing-plan__cycle" data-price-cycle></p>
                <button
                  type="button"
                  class="button-primary button-primary--sm"
                  data-checkout={price_id}
                >
                  Suscribirme
                </button>
              </article>
            </div>
          </section>
      <% end %>

      <p class="billing-footer">
        <.link href={~p"/logout"} method="delete" id="billing-logout">Cerrar sesión</.link>
      </p>
    </div>
    """
  end

  defp status_label(%{status: "trialing"}), do: "Período de prueba"

  defp status_label(%{status: "active", cancel_at_period_end: true}),
    do: "Activa (se cancela al final del período)"

  defp status_label(%{status: "active"}), do: "Activa"
  defp status_label(%{status: "past_due"}), do: "Pago pendiente"
  defp status_label(%{status: "paused"}), do: "Pausada"
  defp status_label(%{status: "canceled"}), do: "Cancelada"
  defp status_label(_), do: "Sin suscripción"

  defp period_label(%{status: "canceled"}), do: "Acceso hasta"
  defp period_label(%{cancel_at_period_end: true}), do: "Acceso hasta"
  defp period_label(_), do: "Próximo cobro"

  defp period_date(%{current_period_ends_at: %DateTime{} = ends_at}),
    do: Calendar.strftime(ends_at, "%d/%m/%Y")

  defp period_date(_), do: nil
end
