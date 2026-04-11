defmodule Phlox.Component do
  @moduledoc """
  Branded UI components for Phlox.

  ## CSS dependency

  Include the spinner stylesheet in your layout:

      <link rel="stylesheet" href={~p"/deps/phlox/priv/static/phlox-spinner.css"}>

  Or copy `priv/static/phlox-spinner.css` into your asset pipeline.
  """

  use Phoenix.Component

  @doc """
  Renders the Phlox three-ring spinner.

  The spinner has two visual states:

    * **Idle** — rings visible and static at staggered angles (0°, 30°, 60°),
      forming a logo mark.
    * **Spinning** — rings animate at different speeds and directions,
      evoking petals in a breeze.

  Toggling `:spinning` from `true` to `false` triggers a collapse-and-bloom
  transition: rings shrink to a point, hold briefly, then bloom back to idle.
  To use this transition, add/remove the `collapsing` class via JS after
  removing `spinning`. See the README for integration examples.

  ## Attributes

    * `:spinning` - whether the spinner is active. Default `false`.
    * `:size` - CSS size value for width/height. Default `"24px"`.
    * `:class` - additional CSS classes to merge.

  ## Examples

      <.spinner spinning={@flow_running} />
      <.spinner spinning size="48px" />
      <.spinner />
  """
  attr :spinning, :boolean, default: false
  attr :size, :string, default: "24px"
  attr :class, :string, default: ""

  def spinner(assigns) do
    ~H"""
    <span
      class={["phlox-spinner", @spinning && "spinning", @class]}
      style={"--phlox-spinner-size: #{@size}"}
      role="status"
      aria-label={if @spinning, do: "Loading", else: "Idle"}
    >
      <span class="phlox-ring phlox-ring-outer"></span>
      <span class="phlox-ring phlox-ring-middle"></span>
      <span class="phlox-ring phlox-ring-inner"></span>
    </span>
    """
  end
end
