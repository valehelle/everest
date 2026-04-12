defmodule InventoryReservation do
  @moduledoc """
  Public API for the Inventory Reservation system.

  Starts a ProductServer on demand when a product is first accessed,
  then delegates reserve/confirm/cancel operations to it.
  """

  alias InventoryReservation.ProductServer

  def start_product(product_id, stock) do
    case DynamicSupervisor.start_child(
           InventoryReservation.DynamicSupervisor,
           {ProductServer, product_id: product_id, stock: stock}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  def reserve(product_id, user_id) do
    ProductServer.reserve(product_id, user_id)
  end

  def confirm(product_id, reservation_id) do
    ProductServer.confirm(product_id, reservation_id)
  end

  def cancel(product_id, reservation_id) do
    ProductServer.cancel(product_id, reservation_id)
  end

  def status(product_id) do
    ProductServer.status(product_id)
  end
end
