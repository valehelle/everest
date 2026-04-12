defmodule InventoryReservation.Repo.Migrations.CreateProductsAndReservations do
  use Ecto.Migration

  def change do
    create table(:products) do
      add :product_id, :string, null: false
      add :total_stock, :integer, null: false, default: 0
      add :confirmed_sales, :integer, null: false, default: 0

      timestamps()
    end

    create unique_index(:products, [:product_id])

    create table(:reservations) do
      add :reservation_id, :string, null: false
      add :product_id, :string, null: false
      add :user_id, :string, null: false
      add :status, :string, null: false, default: "active"

      timestamps()
    end

    create unique_index(:reservations, [:reservation_id])
    create index(:reservations, [:product_id, :status])
  end
end
