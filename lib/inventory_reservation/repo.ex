defmodule InventoryReservation.Repo do
  use Ecto.Repo,
    otp_app: :inventory_reservation,
    adapter: Ecto.Adapters.Postgres
end
