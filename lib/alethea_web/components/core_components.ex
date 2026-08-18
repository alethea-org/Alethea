defmodule AletheaWeb.CoreComponents do
  @moduledoc """
  The application's core UI components.

  Every component here renders classes defined in
  `priv/static/assets/css/editorial.css` — the implementation of the
  editorial design system documented in `docs/design/DESIGN.md`.
  There is no utility-class framework and no component CDN behind
  the app, so a class that is not in that file paints nothing.

  Icons live in `AletheaWeb.Icons` and are imported alongside this
  module; call them as `<.icon name="hero-…" />`.
  """
  use Phoenix.Component

  import AletheaWeb.Icons

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:info} phx-mounted={show("#flash")}>Welcome Back!</.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class={["flash", @kind == :info && "flash--info", @kind == :error && "flash--error"]}
      {@rest}
    >
      <.icon
        name={if @kind == :info, do: "hero-information-circle", else: "hero-exclamation-circle"}
        class="flash__icon"
      />
      <div>
        <p :if={@title} class="flash__title">{@title}</p>

        <p class="flash__msg">{msg}</p>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button with navigation support.

  The `variant` picks which of the documented button roles the
  element speaks with: `primary` is the near-black brand action
  (one per viewport), `secondary` is the white hairline pair.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled)
  attr :class, :any, default: nil
  attr :variant, :string, default: "primary", values: ~w(primary secondary)
  attr :size, :string, default: "md", values: ~w(md sm)
  slot :inner_block, required: true

  def button(assigns) do
    base = if assigns.variant == "secondary", do: "button-secondary", else: "button-primary"

    assigns =
      assign(assigns, :class, [base, assigns.size == "sm" && "#{base}--sm", assigns.class])

    if assigns.rest[:href] || assigns.rest[:navigate] || assigns.rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>{render_slot(@inner_block)}</.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>{render_slot(@inner_block)}</button>
      """
    end
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://hexdocs.pm/phoenix_html/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :hint, :string, default: nil, doc: "help text rendered under the control"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="field">
      <label for={@id} class="checkbox-row">
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          class={@class}
          {@rest}
        /> <span>{@label}</span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="field">
      <label :if={@label} for={@id} class="field__label">{@label}</label>
      <select
        id={@id}
        name={@name}
        class={[@class || "text-input", @errors != [] && "text-input--error"]}
        multiple={@multiple}
        {@rest}
      >
        <option :if={@prompt} value="">{@prompt}</option>
        {Phoenix.HTML.Form.options_for_select(@options, @value)}
      </select>
      <p :if={@hint && @errors == []} class="field__hint">{@hint}</p>

      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="field">
      <label :if={@label} for={@id} class="field__label">{@label}</label> <textarea
        id={@id}
        name={@name}
        class={[
          @class || "text-input text-input--multiline",
          @errors != [] && "text-input--error"
        ]}
        {@rest}
      >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      <p :if={@hint && @errors == []} class="field__hint">{@hint}</p>

      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class="field">
      <label :if={@label} for={@id} class="field__label">{@label}</label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        class={[@class || "text-input", @errors != [] && "text-input--error"]}
        {@rest}
      />
      <p :if={@hint && @errors == []} class="field__hint">{@hint}</p>

      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  @doc """
  Renders a simple error message.
  """
  slot :inner_block, required: true

  def error(assigns) do
    ~H"""
    <p class="field__error">
      <.icon name="hero-exclamation-circle" class="size-3" /> {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders the editorial page header: eyebrow, display title and an
  optional action cluster.
  """
  slot :inner_block, required: true
  slot :eyebrow
  slot :subtitle
  slot :actions

  attr :class, :any, default: nil
  attr :rest, :global

  def header(assigns) do
    ~H"""
    <header class={["page-head", @class]} {@rest}>
      <div>
        <p :if={@eyebrow != []} class="pt-eyebrow">{render_slot(@eyebrow)}</p>

        <h1 class="pt-h1">{render_slot(@inner_block)}</h1>

        <p :if={@subtitle != []} class="pt-muted">{render_slot(@subtitle)}</p>
      </div>

      <div :if={@actions != []} class="page-head__actions">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <div class="data-table-wrap">
      <table class="data-table">
        <thead>
          <tr>
            <th :for={col <- @col}>{col[:label]}</th>

            <th :if={@action != []}><span class="sr-only">Acciones</span></th>
          </tr>
        </thead>

        <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
          <tr :for={row <- @rows} id={@row_id && @row_id.(row)}>
            <td :for={col <- @col} phx-click={@row_click && @row_click.(row)}>
              {render_slot(col, @row_item.(row))}
            </td>

            <td :if={@action != []}>
              <div class="data-table__actions">
                <%= for action <- @action do %>
                  {render_slot(action, @row_item.(row))}
                <% end %>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <dl class="detail-list">
      <div :for={item <- @item} class="detail-list__row">
        <dt>{item.title}</dt>

        <dd>{render_slot(item)}</dd>
      </div>
    </dl>
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js, to: selector, time: 200)
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js, to: selector, time: 150)
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # You can make use of gettext to translate error messages by
    # uncommenting and adjusting the following code:

    # if count = opts[:count] do
    #   Gettext.dngettext(AletheaWeb.Gettext, "errors", msg, msg, count, opts)
    # else
    #   Gettext.dgettext(AletheaWeb.Gettext, "errors", msg, opts)
    # end

    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end

  @doc """
  Renders a simple form.

  ## Examples

      <.simple_form for={@form} phx-change="validate" phx-submit="save">
        <.input field={@form[:email]} label="Email"/>
        <.input field={@form[:username]} label="Username" />
        <:actions>
          <.button>Save</.button>
        </:actions>
      </.simple_form>
  """
  attr :for, :any, required: true, doc: "the datastructure for the form"
  attr :as, :any, default: nil, doc: "the server side parameter to collect all input under"

  attr :rest, :global,
    include: ~w(autocomplete name rel action enctype method novalidate target multipart),
    doc: "the arbitrary HTML attributes to apply to the form tag"

  slot :inner_block, required: true
  slot :actions, doc: "the slot for form actions, such as a submit button"

  def simple_form(assigns) do
    ~H"""
    <.form :let={f} for={@for} as={@as} {@rest}>
      {render_slot(@inner_block, f)}
      <div :for={action <- @actions} class="form-actions">{render_slot(action, f)}</div>
    </.form>
    """
  end

  @doc """
  Renders a modal.

  ## Examples

      <.modal id="confirm-modal">
        This is a modal.
      </.modal>

  JS commands may be passed to the `:on_cancel` to configure
  the closing/cancel event, for example:

      <.modal id="confirm" on_cancel={JS.navigate(~p"/posts")}>
        Is this certainly the case?
      </.modal>
  """
  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :title, :string, default: nil
  attr :on_cancel, Phoenix.LiveView.JS, default: %JS{}
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <dialog
      id={@id}
      class="pta-modal"
      onclose={render_slot(@on_cancel)}
      phx-mounted={@show && show_modal(@id)}
      phx-remove={hide_modal(@id)}
    >
      <div class="pta-modal__head">
        <h3 class="pta-modal__title">{@title}</h3>

        <button
          type="button"
          class="pta-modal__close"
          aria-label="Cerrar"
          phx-click={JS.exec(@on_cancel, "phx-remove") |> hide_modal(@id)}
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>

      <div class="pta-modal__body">{render_slot(@inner_block)}</div>
    </dialog>
    """
  end

  @doc """
  Renders a status pill.

  The color maps to the documented semantic roles, never to a new
  accent: `ok` is the success role, `warn` the warn role, `danger`
  the danger role, `neutral` the soft surface.
  """
  attr :tone, :atom, default: :neutral, values: [:ok, :warn, :danger, :neutral]
  attr :rest, :global
  slot :inner_block, required: true

  def badge(assigns) do
    ~H"""
    <span class={["pt-pill", "pt-pill--#{@tone}"]} {@rest}>{render_slot(@inner_block)}</span>
    """
  end

  def show_modal(js \\ %JS{}, id) when is_binary(id) do
    js
    |> JS.show(to: "##{id}")
    |> JS.dispatch("js:show-modal", to: "##{id}")
  end

  def hide_modal(js \\ %JS{}, id) when is_binary(id) do
    js
    |> JS.hide(to: "##{id}")
    |> JS.dispatch("js:hide-modal", to: "##{id}")
  end
end
