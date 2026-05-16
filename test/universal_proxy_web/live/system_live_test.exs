defmodule UniversalProxyWeb.SystemLiveTest do
  @moduledoc """
  Targeted assertions for the firmware-update behavior layered onto
  the System tab in Phase 5. The full-render smoke check lives in
  [render_smoke_test.exs](render_smoke_test.exs); this file focuses
  on the new firmware UI states.
  """

  use ExUnit.Case, async: false
  import Phoenix.LiveViewTest
  import Phoenix.ConnTest

  alias UniversalProxy.FirmwareUpdate

  @endpoint UniversalProxyWeb.Endpoint

  setup do
    # Restore safe defaults after any individual test mutated config.
    on_exit(fn -> FirmwareUpdate.update_config(verification_required: false) end)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  test "renders the Firmware card with the validated/pending badge", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/system")

    assert html =~ "Firmware"
    # Either validated or pending — both are valid on host
    assert html =~ "Validated" or html =~ "Pending validation"
  end

  test "hides the check-for-updates action row on host", %{conn: conn} do
    # On host, `Mix.target() == :host` so `@show_fw_actions == false`
    {:ok, _view, html} = live(conn, "/system")

    refute html =~ "Check for updates"
    refute html =~ ~s|phx-click="fw_check"|
  end

  test "shows the 'Signature checks disabled' warning badge by default", %{conn: conn} do
    :ok = FirmwareUpdate.update_config(verification_required: false)

    {:ok, _view, html} = live(conn, "/system")

    assert html =~ "Signature checks disabled"
  end

  test "warning badge disappears once verification_required is true", %{conn: conn} do
    :ok = FirmwareUpdate.update_config(verification_required: true)

    {:ok, _view, html} = live(conn, "/system")

    refute html =~ "Signature checks disabled"
  end
end
