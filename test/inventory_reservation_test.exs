defmodule InventoryReservationTest do
  use ExUnit.Case, async: false

  alias InventoryReservation.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    product_id = "product_#{:erlang.unique_integer([:positive])}"
    {:ok, product_id: product_id}
  end

  # --- Level 1: Basic Inventory Reservation ---

  describe "basic reservation" do
    test "reserves item when stock available", %{product_id: product_id} do
      InventoryReservation.start_product(product_id, 1)

      assert {:ok, _reservation_id} = InventoryReservation.reserve(product_id, "user_a")
    end

    test "rejects reservation when out of stock", %{product_id: product_id} do
      InventoryReservation.start_product(product_id, 1)

      assert {:ok, _} = InventoryReservation.reserve(product_id, "user_a")
      assert {:error, :out_of_stock} = InventoryReservation.reserve(product_id, "user_b")
    end

    test "allows multiple reservations up to stock limit", %{product_id: product_id} do
      InventoryReservation.start_product(product_id, 3)

      assert {:ok, _} = InventoryReservation.reserve(product_id, "user_a")
      assert {:ok, _} = InventoryReservation.reserve(product_id, "user_b")
      assert {:ok, _} = InventoryReservation.reserve(product_id, "user_c")
      assert {:error, :out_of_stock} = InventoryReservation.reserve(product_id, "user_d")
    end

    test "tracks available stock correctly", %{product_id: product_id} do
      InventoryReservation.start_product(product_id, 5)

      InventoryReservation.reserve(product_id, "user_a")
      InventoryReservation.reserve(product_id, "user_b")

      status = InventoryReservation.status(product_id)
      assert status.total_stock == 5
      assert status.active_reservations == 2
      assert status.available_stock == 3
    end
  end

  # --- Level 2: Reservation Lifecycle ---

  describe "confirm reservation" do
    test "confirms an active reservation", %{product_id: product_id} do
      InventoryReservation.start_product(product_id, 1)

      {:ok, reservation_id} = InventoryReservation.reserve(product_id, "user_a")
      assert {:ok, :confirmed} = InventoryReservation.confirm(product_id, reservation_id)

      status = InventoryReservation.status(product_id)
      assert status.confirmed_sales == 1
      assert status.available_stock == 0
    end

    test "cannot confirm twice", %{product_id: product_id} do
      InventoryReservation.start_product(product_id, 1)

      {:ok, reservation_id} = InventoryReservation.reserve(product_id, "user_a")
      InventoryReservation.confirm(product_id, reservation_id)

      assert {:error, :already_confirmed} =
               InventoryReservation.confirm(product_id, reservation_id)
    end

    test "cannot confirm a cancelled reservation", %{product_id: product_id} do
      InventoryReservation.start_product(product_id, 1)

      {:ok, reservation_id} = InventoryReservation.reserve(product_id, "user_a")
      InventoryReservation.cancel(product_id, reservation_id)

      assert {:error, :reservation_cancelled} =
               InventoryReservation.confirm(product_id, reservation_id)
    end

    test "cannot confirm a non-existent reservation", %{product_id: product_id} do
      InventoryReservation.start_product(product_id, 1)

      assert {:error, :not_found} = InventoryReservation.confirm(product_id, "fake_id")
    end
  end

  describe "cancel reservation" do
    test "cancels an active reservation and releases stock", %{product_id: product_id} do
      InventoryReservation.start_product(product_id, 1)

      {:ok, reservation_id} = InventoryReservation.reserve(product_id, "user_a")
      assert {:ok, :cancelled} = InventoryReservation.cancel(product_id, reservation_id)

      status = InventoryReservation.status(product_id)
      assert status.available_stock == 1
    end

    test "another user can reserve after cancellation", %{product_id: product_id} do
      InventoryReservation.start_product(product_id, 1)

      {:ok, reservation_id} = InventoryReservation.reserve(product_id, "user_a")
      InventoryReservation.cancel(product_id, reservation_id)

      assert {:ok, _} = InventoryReservation.reserve(product_id, "user_b")
    end

    test "cannot cancel a confirmed reservation", %{product_id: product_id} do
      InventoryReservation.start_product(product_id, 1)

      {:ok, reservation_id} = InventoryReservation.reserve(product_id, "user_a")
      InventoryReservation.confirm(product_id, reservation_id)

      assert {:error, :cannot_cancel_confirmed} =
               InventoryReservation.cancel(product_id, reservation_id)
    end
  end

  describe "expiry" do
    test "expired reservation releases stock", %{product_id: product_id} do
      InventoryReservation.start_product(product_id, 1)

      {:ok, reservation_id} = InventoryReservation.reserve(product_id, "user_a")

      [{pid, _}] = Registry.lookup(InventoryReservation.Registry, product_id)
      send(pid, {:expire, reservation_id})
      :timer.sleep(10)

      status = InventoryReservation.status(product_id)
      assert status.available_stock == 1
    end

    test "cannot confirm an expired reservation", %{product_id: product_id} do
      InventoryReservation.start_product(product_id, 1)

      {:ok, reservation_id} = InventoryReservation.reserve(product_id, "user_a")

      [{pid, _}] = Registry.lookup(InventoryReservation.Registry, product_id)
      send(pid, {:expire, reservation_id})
      :timer.sleep(10)

      assert {:error, :reservation_expired} =
               InventoryReservation.confirm(product_id, reservation_id)
    end

    test "another user can reserve after expiry", %{product_id: product_id} do
      InventoryReservation.start_product(product_id, 1)

      {:ok, reservation_id} = InventoryReservation.reserve(product_id, "user_a")

      [{pid, _}] = Registry.lookup(InventoryReservation.Registry, product_id)
      send(pid, {:expire, reservation_id})
      :timer.sleep(10)

      assert {:ok, _} = InventoryReservation.reserve(product_id, "user_b")
    end
  end

  # --- Level 3: Concurrency ---

  describe "concurrency" do
    test "500 simultaneous requests for 1 item, only 1 succeeds", %{product_id: product_id} do
      InventoryReservation.start_product(product_id, 1)

      tasks =
        Enum.map(1..500, fn i ->
          Task.async(fn ->
            InventoryReservation.reserve(product_id, "user_#{i}")
          end)
        end)

      results = Task.await_many(tasks, 10_000)

      successes = Enum.count(results, &match?({:ok, _}, &1))
      failures = Enum.count(results, &match?({:error, :out_of_stock}, &1))

      assert successes == 1
      assert failures == 499
    end

    test "10 stock with 500 simultaneous requests", %{product_id: product_id} do
      InventoryReservation.start_product(product_id, 10)

      tasks =
        Enum.map(1..500, fn i ->
          Task.async(fn ->
            InventoryReservation.reserve(product_id, "user_#{i}")
          end)
        end)

      results = Task.await_many(tasks, 10_000)

      successes = Enum.count(results, &match?({:ok, _}, &1))
      failures = Enum.count(results, &match?({:error, :out_of_stock}, &1))

      assert successes == 10
      assert failures == 490
    end

    test "concurrent start_product calls don't create duplicates", %{product_id: product_id} do
      tasks =
        Enum.map(1..100, fn _ ->
          Task.async(fn ->
            InventoryReservation.start_product(product_id, 1)
          end)
        end)

      results = Task.await_many(tasks, 5_000)

      pids = Enum.map(results, fn {:ok, pid} -> pid end)
      assert Enum.uniq(pids) |> length() == 1
    end
  end
end
