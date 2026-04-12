defmodule InventoryReservation.Schema.Product do
  use Ecto.Schema
  import Ecto.Changeset

  schema "products" do
    field :product_id, :string
    field :total_stock, :integer, default: 0
    field :confirmed_sales, :integer, default: 0

    timestamps()
  end

  def changeset(product, attrs) do
    product
    |> cast(attrs, [:product_id, :total_stock, :confirmed_sales])
    |> validate_required([:product_id, :total_stock])
    |> unique_constraint(:product_id)
  end
end
