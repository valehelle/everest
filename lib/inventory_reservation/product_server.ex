defmodule InventoryReservation.ProductServer do
  @moduledoc """
  GenServer that manages inventory for a single product.

  Each product gets its own GenServer process, started on demand via DynamicSupervisor.
  The GenServer mailbox naturally serializes all concurrent requests — no manual
  locks or mutexes needed.

  ## Locking Strategy

  This system uses the Actor Model (OTP GenServer) as its concurrency control mechanism:

  1. **No manual locks** — The GenServer processes one message at a time from its mailbox.
     Even if 500 processes send `:reserve` simultaneously, they queue in the mailbox
     and execute sequentially. This eliminates race conditions by design.

  2. **Registry for unique processes** — Erlang's Registry uses ETS atomic operations
     (`insert_new`) to guarantee exactly one GenServer per product. Two concurrent
     `start_child` calls for the same product will never create duplicates.

  3. **Expiry safety** — `Process.send_after/3` schedules expiry messages into the same
     mailbox. A confirm and an expire arriving at the same instant are still processed
     one at a time — no inconsistent state is possible.

  Available Stock = Total Stock − Confirmed Sales − Active Reservations
  """

  use GenServer

  alias InventoryReservation.Repo
  alias InventoryReservation.Schema.Product
  alias InventoryReservation.Schema.Reservation

  @reservation_ttl :timer.minutes(2)

  # --- Client API ---

  def start_link(opts) do
    product_id = Keyword.fetch!(opts, :product_id)
    stock = Keyword.fetch!(opts, :stock)

    GenServer.start_link(__MODULE__, %{product_id: product_id, stock: stock},
      name: via(product_id)
    )
  end

  def reserve(product_id, user_id) do
    GenServer.call(via(product_id), {:reserve, user_id})
  end

  def confirm(product_id, reservation_id) do
    GenServer.call(via(product_id), {:confirm, reservation_id})
  end

  def cancel(product_id, reservation_id) do
    GenServer.call(via(product_id), {:cancel, reservation_id})
  end

  def status(product_id) do
    GenServer.call(via(product_id), :status)
  end

  defp via(product_id) do
    {:via, Registry, {InventoryReservation.Registry, product_id}}
  end

  # --- Server Callbacks ---

  @impl true
  def init(%{product_id: product_id, stock: stock}) do
    # Persist product to DB
    product =
      case Repo.get_by(Product, product_id: product_id) do
        nil ->
          %Product{}
          |> Product.changeset(%{product_id: product_id, total_stock: stock})
          |> Repo.insert!()

        existing ->
          existing
      end

    # Load any active reservations from DB (recovery after crash)
    active_reservations =
      Reservation
      |> Reservation.active_for_product(product_id)
      |> Repo.all()

    reservations =
      Map.new(active_reservations, fn r ->
        timer_ref = Process.send_after(self(), {:expire, r.reservation_id}, @reservation_ttl)

        {r.reservation_id,
         %{
           user_id: r.user_id,
           status: :active,
           timer_ref: timer_ref,
           created_at: System.monotonic_time(:millisecond),
           db_id: r.id
         }}
      end)

    state = %{
      product_id: product_id,
      total_stock: product.total_stock,
      confirmed_sales: product.confirmed_sales,
      reservations: reservations,
      db_id: product.id
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:reserve, user_id}, _from, state) do
    available = available_stock(state)

    if available > 0 do
      reservation_id = generate_id()
      timer_ref = Process.send_after(self(), {:expire, reservation_id}, @reservation_ttl)

      # Persist to DB
      {:ok, db_reservation} =
        %Reservation{}
        |> Reservation.changeset(%{
          reservation_id: reservation_id,
          product_id: state.product_id,
          user_id: user_id,
          status: "active"
        })
        |> Repo.insert()

      reservation = %{
        user_id: user_id,
        status: :active,
        timer_ref: timer_ref,
        created_at: System.monotonic_time(:millisecond),
        db_id: db_reservation.id
      }

      new_state = put_in(state, [:reservations, reservation_id], reservation)
      broadcast(state.product_id)
      {:reply, {:ok, reservation_id}, new_state}
    else
      {:reply, {:error, :out_of_stock}, state}
    end
  end

  @impl true
  def handle_call({:confirm, reservation_id}, _from, state) do
    case get_in(state, [:reservations, reservation_id]) do
      %{status: :active} = reservation ->
        Process.cancel_timer(reservation.timer_ref)

        # Update DB
        Repo.get!(Reservation, reservation.db_id)
        |> Reservation.changeset(%{status: "confirmed"})
        |> Repo.update!()

        Repo.get!(Product, state.db_id)
        |> Product.changeset(%{confirmed_sales: state.confirmed_sales + 1})
        |> Repo.update!()

        new_state =
          state
          |> put_in([:reservations, reservation_id], %{reservation | status: :confirmed})
          |> Map.update!(:confirmed_sales, &(&1 + 1))

        broadcast(state.product_id)
        {:reply, {:ok, :confirmed}, new_state}

      %{status: :confirmed} ->
        {:reply, {:error, :already_confirmed}, state}

      %{status: :cancelled} ->
        {:reply, {:error, :reservation_cancelled}, state}

      %{status: :expired} ->
        {:reply, {:error, :reservation_expired}, state}

      nil ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:cancel, reservation_id}, _from, state) do
    case get_in(state, [:reservations, reservation_id]) do
      %{status: :active} = reservation ->
        Process.cancel_timer(reservation.timer_ref)

        # Update DB
        Repo.get!(Reservation, reservation.db_id)
        |> Reservation.changeset(%{status: "cancelled"})
        |> Repo.update!()

        new_state =
          put_in(state, [:reservations, reservation_id], %{reservation | status: :cancelled})

        broadcast(state.product_id)
        {:reply, {:ok, :cancelled}, new_state}

      %{status: status} ->
        {:reply, {:error, :"cannot_cancel_#{status}"}, state}

      nil ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    info = %{
      product_id: state.product_id,
      total_stock: state.total_stock,
      confirmed_sales: state.confirmed_sales,
      active_reservations: count_active(state),
      available_stock: available_stock(state)
    }

    {:reply, info, state}
  end

  @impl true
  def handle_info({:expire, reservation_id}, state) do
    case get_in(state, [:reservations, reservation_id]) do
      %{status: :active} = reservation ->
        # Update DB
        Repo.get!(Reservation, reservation.db_id)
        |> Reservation.changeset(%{status: "expired"})
        |> Repo.update!()

        new_state =
          put_in(state, [:reservations, reservation_id], %{reservation | status: :expired})

        broadcast(state.product_id)
        {:noreply, new_state}

      _other ->
        {:noreply, state}
    end
  end

  # --- Private Helpers ---

  defp available_stock(state) do
    state.total_stock - state.confirmed_sales - count_active(state)
  end

  defp count_active(state) do
    state.reservations
    |> Map.values()
    |> Enum.count(&(&1.status == :active))
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  defp broadcast(product_id) do
    Phoenix.PubSub.broadcast(
      InventoryReservation.PubSub,
      "product:#{product_id}",
      :status_changed
    )
  end
end
