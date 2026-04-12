defmodule InventoryReservationWeb.PageController do
  use InventoryReservationWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
