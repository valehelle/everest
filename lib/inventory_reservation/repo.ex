defmodule InventoryReservation.Repo do
  use Ecto.Repo,
    otp_app: :inventory_reservation,
    adapter: Application.compile_env(:inventory_reservation, :ecto_adapter, Ecto.Adapters.Postgres)
end
