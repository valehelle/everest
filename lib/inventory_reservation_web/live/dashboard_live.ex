defmodule InventoryReservationWeb.DashboardLive do
  use InventoryReservationWeb, :live_view

  @reservation_ttl_ms :timer.minutes(2)

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        product_name: "Limited Edition Sneakers",
        stock_input: "10",
        user_count: "500",
        phase: :setup,
        product_id: nil,
        status: nil,
        results: [],
        log: [],
        ttl_ms: @reservation_ttl_ms,
        elapsed_ms: nil
      )

    {:ok, socket}
  end

  # --- Phase 1: Setup → Create users + product ---

  @impl true
  def handle_event("create_users", params, socket) do
    %{"product_name" => name, "stock" => stock_str, "user_count" => user_count_str} = params
    stock = String.to_integer(stock_str)
    user_count = user_count_str |> String.to_integer() |> min(500)
    product_id = generate_product_id()

    {:ok, _} = InventoryReservation.start_product(product_id, stock)
    Phoenix.PubSub.subscribe(InventoryReservation.PubSub, "product:#{product_id}")
    status = InventoryReservation.status(product_id)

    users =
      Enum.map(1..user_count, fn i ->
        %{user: "user_#{i}", index: i, status: :waiting, reservation_id: nil, created_at_ms: nil}
      end)

    socket =
      socket
      |> assign(
        product_id: product_id,
        product_name: name,
        stock_input: stock_str,
        user_count: user_count_str,
        phase: :ready,
        results: users,
        status: status
      )
      |> add_log(:ok, "Product created: #{name} — #{stock} units")
      |> add_log(:info, "#{user_count} users ready. Press FIRE to start the race.")

    {:noreply, socket}
  end

  # --- Phase 2: Fire all concurrent reserves ---

  @impl true
  def handle_event("fire", _params, socket) do
    product_id = socket.assigns.product_id
    users = socket.assigns.results

    socket = add_log(socket, :info, "Spawning #{length(users)} concurrent BEAM processes...")

    t_start = System.monotonic_time(:microsecond)

    shuffled = Enum.shuffle(users)

    tasks =
      Enum.map(shuffled, fn u ->
        Task.async(fn ->
          {u.index, InventoryReservation.reserve(product_id, u.user)}
        end)
      end)

    raw_results = Task.await_many(tasks, 30_000)
    t_end = System.monotonic_time(:microsecond)
    elapsed_ms = Float.round((t_end - t_start) / 1000, 1)

    now_ms = System.system_time(:millisecond)
    status = InventoryReservation.status(product_id)

    results =
      raw_results
      |> Enum.map(fn
        {i, {:ok, rid}} ->
          %{user: "user_#{i}", index: i, status: :reserved, reservation_id: rid, created_at_ms: now_ms}

        {i, {:error, _}} ->
          %{user: "user_#{i}", index: i, status: :rejected, reservation_id: nil, created_at_ms: nil}
      end)
      |> Enum.sort_by(fn r -> {if(r.status == :reserved, do: 0, else: 1), r.index} end)

    reserved = Enum.count(results, &(&1.status == :reserved))
    rejected = Enum.count(results, &(&1.status == :rejected))

    socket =
      socket
      |> assign(phase: :results, results: results, status: status, elapsed_ms: elapsed_ms)
      |> add_log(:ok, "Done in #{elapsed_ms}ms — #{reserved} reserved, #{rejected} rejected")

    {:noreply, socket}
  end

  # --- Actions on results ---

  @impl true
  def handle_event("confirm", %{"rid" => rid, "user" => user}, socket) do
    case InventoryReservation.confirm(socket.assigns.product_id, rid) do
      {:ok, :confirmed} ->
        socket =
          socket
          |> update_result(rid, :confirmed)
          |> refresh_status()
          |> add_log(:ok, "Confirmed #{user}")

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, add_log(socket, :err, "Confirm #{user} failed: #{reason}")}
    end
  end

  @impl true
  def handle_event("cancel", %{"rid" => rid, "user" => user}, socket) do
    case InventoryReservation.cancel(socket.assigns.product_id, rid) do
      {:ok, :cancelled} ->
        socket =
          socket
          |> update_result(rid, :cancelled)
          |> refresh_status()
          |> add_log(:ok, "Cancelled #{user}")

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, add_log(socket, :err, "Cancel #{user} failed: #{reason}")}
    end
  end

  @impl true
  def handle_event("confirm_all", _params, socket) do
    reserved = Enum.filter(socket.assigns.results, &(&1.status == :reserved))

    {results, count} =
      Enum.reduce(reserved, {socket.assigns.results, 0}, fn r, {res, c} ->
        case InventoryReservation.confirm(socket.assigns.product_id, r.reservation_id) do
          {:ok, :confirmed} ->
            {set_result_status(res, r.reservation_id, :confirmed), c + 1}

          {:error, _} ->
            {res, c}
        end
      end)

    socket =
      socket
      |> assign(results: results)
      |> refresh_status()
      |> add_log(:ok, "Confirmed #{count} reservations")

    {:noreply, socket}
  end

  @impl true
  def handle_event("cancel_all", _params, socket) do
    reserved = Enum.filter(socket.assigns.results, &(&1.status == :reserved))

    {results, count} =
      Enum.reduce(reserved, {socket.assigns.results, 0}, fn r, {res, c} ->
        case InventoryReservation.cancel(socket.assigns.product_id, r.reservation_id) do
          {:ok, :cancelled} ->
            {set_result_status(res, r.reservation_id, :cancelled), c + 1}

          {:error, _} ->
            {res, c}
        end
      end)

    socket =
      socket
      |> assign(results: results)
      |> refresh_status()
      |> add_log(:ok, "Cancelled #{count} reservations")

    {:noreply, socket}
  end

  @impl true
  def handle_event("fire_again", _params, socket) do
    product_id = socket.assigns.product_id
    status = InventoryReservation.status(product_id)

    if status.available_stock == 0 do
      {:noreply, add_log(socket, :err, "No stock available to reserve")}
    else
      # Collect users that can retry (rejected, cancelled, expired)
      retryable =
        Enum.filter(socket.assigns.results, &(&1.status in [:rejected, :cancelled, :expired]))

      if retryable == [] do
        {:noreply, add_log(socket, :err, "No users available to retry")}
      else
        socket = add_log(socket, :info, "Re-firing #{length(retryable)} users for #{status.available_stock} remaining stock...")

        t_start = System.monotonic_time(:microsecond)

        shuffled = Enum.shuffle(retryable)

        tasks =
          Enum.map(shuffled, fn u ->
            Task.async(fn ->
              {u.index, InventoryReservation.reserve(product_id, u.user)}
            end)
          end)

        raw_results = Task.await_many(tasks, 30_000)
        t_end = System.monotonic_time(:microsecond)
        elapsed_ms = Float.round((t_end - t_start) / 1000, 1)
        now_ms = System.system_time(:millisecond)

        # Build a map of new results by index
        new_by_index =
          Map.new(raw_results, fn
            {i, {:ok, rid}} ->
              {i, %{status: :reserved, reservation_id: rid, created_at_ms: now_ms}}
            {i, {:error, _}} ->
              {i, %{status: :rejected}}
          end)

        # Merge into existing results
        results =
          Enum.map(socket.assigns.results, fn r ->
            case Map.get(new_by_index, r.index) do
              %{status: :reserved} = new ->
                %{r | status: :reserved, reservation_id: new.reservation_id, created_at_ms: new.created_at_ms}
              %{status: :rejected} ->
                %{r | status: :rejected}
              nil ->
                r
            end
          end)
          |> Enum.sort_by(fn r ->
            order = %{reserved: 0, confirmed: 1, rejected: 2, cancelled: 3, expired: 4}
            {Map.get(order, r.status, 5), r.index}
          end)

        new_reserved = Enum.count(raw_results, fn {_, res} -> match?({:ok, _}, res) end)
        new_rejected = Enum.count(raw_results, fn {_, res} -> match?({:error, _}, res) end)
        new_status = InventoryReservation.status(product_id)

        socket =
          socket
          |> assign(results: results, status: new_status, elapsed_ms: elapsed_ms)
          |> add_log(:ok, "Re-fire done in #{elapsed_ms}ms — #{new_reserved} reserved, #{new_rejected} rejected")

        {:noreply, socket}
      end
    end
  end

  @impl true
  def handle_event("reset", _params, socket) do
    {:noreply,
     assign(socket,
       phase: :setup,
       product_id: nil,
       status: nil,
       results: [],
       log: [],
       elapsed_ms: nil
     )}
  end

  # --- PubSub ---

  @impl true
  def handle_info(:status_changed, socket) do
    if socket.assigns.phase == :results do
      status = InventoryReservation.status(socket.assigns.product_id)
      now_ms = System.system_time(:millisecond)

      results =
        Enum.map(socket.assigns.results, fn r ->
          if r.status == :reserved && r.created_at_ms &&
               now_ms - r.created_at_ms >= @reservation_ttl_ms do
            %{r | status: :expired}
          else
            r
          end
        end)

      {:noreply, assign(socket, status: status, results: results)}
    else
      {:noreply, socket}
    end
  end

  # --- Helpers ---

  defp update_result(socket, rid, new_status) do
    results = set_result_status(socket.assigns.results, rid, new_status)
    assign(socket, results: results)
  end

  defp set_result_status(results, rid, new_status) do
    Enum.map(results, fn r ->
      if r.reservation_id == rid, do: %{r | status: new_status}, else: r
    end)
  end

  defp refresh_status(socket) do
    status = InventoryReservation.status(socket.assigns.product_id)
    assign(socket, status: status)
  end

  defp add_log(socket, type, msg) do
    entry = %{type: type, msg: msg, time: Calendar.strftime(DateTime.utc_now(), "%H:%M:%S")}
    update(socket, :log, &[entry | Enum.take(&1, 199)])
  end

  defp generate_product_id do
    :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
  end

  defp count_by_status(results, status) do
    Enum.count(results, &(&1.status == status))
  end

  defp status_badge(:waiting), do: "badge-ghost"
  defp status_badge(:reserved), do: "badge-warning"
  defp status_badge(:confirmed), do: "badge-success"
  defp status_badge(:cancelled), do: "badge-neutral"
  defp status_badge(:rejected), do: "badge-error"
  defp status_badge(:expired), do: "badge-neutral opacity-50"
  defp status_badge(_), do: "badge-ghost"

  defp status_label(:waiting), do: "WAITING"
  defp status_label(:reserved), do: "RESERVED"
  defp status_label(:confirmed), do: "CONFIRMED"
  defp status_label(:cancelled), do: "CANCELLED"
  defp status_label(:rejected), do: "REJECTED"
  defp status_label(:expired), do: "EXPIRED"
  defp status_label(_), do: "—"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-200">
      <%!-- Navbar --%>
      <div class="navbar bg-base-100 border-b border-base-300 px-6">
        <div class="flex-1 gap-3">
          <span class="hero-cube-transparent w-6 h-6 text-primary" />
          <span class="font-bold">Inventory Reservation</span>
          <span class="text-xs opacity-40">OTP Actor Model Demo</span>
        </div>
        <%= if @product_id do %>
          <div class="flex-none gap-3">
            <code class="text-xs opacity-50">{@product_id}</code>
            <button phx-click="reset" class="btn btn-ghost btn-sm">New Test</button>
          </div>
        <% end %>
      </div>

      <div class="max-w-7xl mx-auto px-6 py-8">
        <%= case @phase do %>
          <% :setup -> %>
            <%!-- ===== SETUP ===== --%>
            <div class="flex items-center justify-center min-h-[70vh]">
              <div class="w-full max-w-lg">
                <div class="text-center mb-8">
                  <span class="hero-bolt w-12 h-12 text-primary mx-auto block mb-3" />
                  <h2 class="text-3xl font-black">Flash Sale Simulator</h2>
                  <p class="text-sm opacity-50 mt-2">
                    Create users, then fire them all at once to compete for limited stock.
                  </p>
                </div>

                <form phx-submit="create_users" class="card bg-base-100 shadow-xl">
                  <div class="card-body space-y-4">
                    <div class="form-control">
                      <label class="label"><span class="label-text">Product Name</span></label>
                      <input name="product_name" value={@product_name}
                        class="input input-bordered" placeholder="e.g. Limited Edition Sneakers" />
                    </div>
                    <div class="grid grid-cols-2 gap-4">
                      <div class="form-control">
                        <label class="label"><span class="label-text">Stock</span></label>
                        <input name="stock" type="number" value={@stock_input} min="1"
                          class="input input-bordered" />
                      </div>
                      <div class="form-control">
                        <label class="label"><span class="label-text">Users</span></label>
                        <input name="user_count" type="number" value={@user_count} min="1" max="500"
                          class="input input-bordered" />
                      </div>
                    </div>
                    <button type="submit" class="btn btn-primary btn-lg w-full gap-2 mt-2">
                      <span class="hero-users w-5 h-5" />
                      Create Users &amp; Product
                    </button>
                  </div>
                </form>
              </div>
            </div>

          <% :ready -> %>
            <%!-- ===== USERS READY, WAITING TO FIRE ===== --%>

            <%!-- Stats bar --%>
            <div class="stats stats-horizontal shadow w-full bg-base-100 mb-6">
              <div class="stat">
                <div class="stat-title">Product</div>
                <div class="stat-value text-lg">{@product_name}</div>
                <div class="stat-desc">{@status.total_stock} units in stock</div>
              </div>
              <div class="stat">
                <div class="stat-title">Stock</div>
                <div class="stat-value text-primary">{@status.total_stock}</div>
                <div class="stat-desc">available</div>
              </div>
              <div class="stat">
                <div class="stat-title">Users</div>
                <div class="stat-value">{length(@results)}</div>
                <div class="stat-desc">waiting to reserve</div>
              </div>
            </div>

            <%!-- Fire button --%>
            <div class="text-center mb-6">
              <button phx-click="fire" class="btn btn-error btn-lg gap-3 px-12 animate-pulse">
                <span class="hero-bolt-solid w-6 h-6" />
                FIRE — {length(@results)} users race for {@status.total_stock} items
              </button>
            </div>

            <%!-- Users grid --%>
            <div class="card bg-base-100 shadow-lg">
              <div class="card-body p-0">
                <div class="px-6 pt-5 pb-3">
                  <h3 class="font-bold flex items-center gap-2">
                    <span class="hero-users w-5 h-5 opacity-50" />
                    Users
                    <span class="badge badge-sm">{length(@results)}</span>
                  </h3>
                </div>
                <div class="overflow-x-auto max-h-[500px] overflow-y-auto">
                  <table class="table table-xs table-pin-rows">
                    <thead>
                      <tr>
                        <th class="w-12">#</th>
                        <th>User</th>
                        <th>Status</th>
                      </tr>
                    </thead>
                    <tbody>
                      <%= for r <- @results do %>
                        <tr>
                          <td class="font-mono text-xs opacity-50">{r.index}</td>
                          <td class="font-mono font-medium">{r.user}</td>
                          <td><span class="badge badge-xs badge-ghost">WAITING</span></td>
                        </tr>
                      <% end %>
                    </tbody>
                  </table>
                </div>
              </div>
            </div>

          <% :results -> %>
            <%!-- ===== RESULTS ===== --%>

            <%!-- Stats bar --%>
            <div class="stats stats-horizontal shadow w-full bg-base-100 mb-6">
              <div class="stat">
                <div class="stat-title">Product</div>
                <div class="stat-value text-lg">{@product_name}</div>
                <div class="stat-desc">{@status.total_stock} total stock</div>
              </div>
              <div class="stat">
                <div class="stat-title">Available</div>
                <div class="stat-value text-primary">{@status.available_stock}</div>
                <div class="stat-desc">of {@status.total_stock}</div>
              </div>
              <div class="stat">
                <div class="stat-title">Reserved</div>
                <div class="stat-value text-warning">{count_by_status(@results, :reserved)}</div>
                <div class="stat-desc">2min TTL</div>
              </div>
              <div class="stat">
                <div class="stat-title">Confirmed</div>
                <div class="stat-value text-success">{@status.confirmed_sales}</div>
                <div class="stat-desc">sold</div>
              </div>
              <div class="stat">
                <div class="stat-title">Rejected</div>
                <div class="stat-value text-error">{count_by_status(@results, :rejected)}</div>
                <div class="stat-desc">out of stock</div>
              </div>
              <div class="stat">
                <div class="stat-title">Time</div>
                <div class="stat-value text-lg">{@elapsed_ms}ms</div>
                <div class="stat-desc">{length(@results)} processes</div>
              </div>
            </div>

            <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
              <%!-- Results table --%>
              <div class="lg:col-span-2">
                <div class="card bg-base-100 shadow-lg">
                  <div class="card-body p-0">
                    <div class="flex items-center justify-between px-6 pt-5 pb-3">
                      <h3 class="font-bold flex items-center gap-2">
                        <span class="hero-users w-5 h-5 opacity-50" />
                        Results
                        <span class="badge badge-sm">{length(@results)}</span>
                      </h3>
                      <div class="flex gap-2">
                        <button phx-click="fire_again" class="btn btn-warning btn-xs gap-1">
                          <span class="hero-bolt w-3 h-3" /> Fire Again
                        </button>
                        <button phx-click="confirm_all" class="btn btn-success btn-xs gap-1"
                          disabled={count_by_status(@results, :reserved) == 0}>
                          <span class="hero-check w-3 h-3" /> Confirm All
                        </button>
                        <button phx-click="cancel_all" class="btn btn-error btn-xs btn-outline gap-1"
                          disabled={count_by_status(@results, :reserved) == 0}>
                          <span class="hero-x-mark w-3 h-3" /> Cancel All
                        </button>
                      </div>
                    </div>

                    <div class="overflow-x-auto max-h-[600px] overflow-y-auto">
                      <table class="table table-xs table-pin-rows">
                        <thead>
                          <tr>
                            <th class="w-12">#</th>
                            <th>User</th>
                            <th>Status</th>
                            <th>TTL</th>
                            <th class="text-right">Actions</th>
                          </tr>
                        </thead>
                        <tbody>
                          <%= for r <- @results do %>
                            <tr class={[
                              r.status == :rejected && "opacity-40",
                              r.status == :expired && "opacity-40"
                            ]}>
                              <td class="font-mono text-xs opacity-50">{r.index}</td>
                              <td class="font-mono font-medium">{r.user}</td>
                              <td>
                                <span class={"badge badge-xs #{status_badge(r.status)}"}>
                                  {status_label(r.status)}
                                </span>
                              </td>
                              <td>
                                <%= if r.status == :reserved do %>
                                  <span
                                    class="font-mono text-xs tabular-nums"
                                    id={"timer-#{r.reservation_id}"}
                                    phx-hook="CountdownTimer"
                                    data-expires-at={r.created_at_ms + @ttl_ms}
                                  />
                                <% end %>
                              </td>
                              <td class="text-right">
                                <%= if r.status == :reserved do %>
                                  <div class="flex gap-1 justify-end">
                                    <button
                                      phx-click="confirm"
                                      phx-value-rid={r.reservation_id}
                                      phx-value-user={r.user}
                                      class="btn btn-success btn-xs"
                                    >
                                      Confirm
                                    </button>
                                    <button
                                      phx-click="cancel"
                                      phx-value-rid={r.reservation_id}
                                      phx-value-user={r.user}
                                      class="btn btn-ghost btn-xs text-error"
                                    >
                                      Cancel
                                    </button>
                                  </div>
                                <% end %>
                              </td>
                            </tr>
                          <% end %>
                        </tbody>
                      </table>
                    </div>
                  </div>
                </div>
              </div>

              <%!-- Event log --%>
              <div>
                <div class="card bg-base-100 shadow-lg">
                  <div class="card-body">
                    <h3 class="font-bold flex items-center gap-2 text-sm">
                      <span class="hero-command-line w-4 h-4 opacity-50" /> Event Log
                    </h3>
                    <div class="mt-3 max-h-[540px] overflow-y-auto font-mono text-xs leading-relaxed bg-base-200 rounded-lg p-3">
                      <%= for entry <- @log do %>
                        <div class={[
                          "py-0.5",
                          entry.type == :ok && "text-success",
                          entry.type == :err && "text-error",
                          entry.type == :info && "text-info"
                        ]}>
                          <span class="opacity-40">{entry.time}</span> {entry.msg}
                        </div>
                      <% end %>
                    </div>
                  </div>
                </div>
              </div>
            </div>
        <% end %>
      </div>
    </div>
    """
  end
end
