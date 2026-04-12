defmodule InventoryReservation.Schema.Reservation do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  schema "reservations" do
    field :reservation_id, :string
    field :product_id, :string
    field :user_id, :string
    field :status, :string, default: "active"

    timestamps()
  end

  def changeset(reservation, attrs) do
    reservation
    |> cast(attrs, [:reservation_id, :product_id, :user_id, :status])
    |> validate_required([:reservation_id, :product_id, :user_id, :status])
    |> validate_inclusion(:status, ["active", "confirmed", "cancelled", "expired"])
    |> unique_constraint(:reservation_id)
  end

  def active_for_product(query, product_id) do
    from r in query,
      where: r.product_id == ^product_id and r.status == "active"
  end
end
