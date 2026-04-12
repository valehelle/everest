defmodule InventoryReservation.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      InventoryReservationWeb.Telemetry,
      InventoryReservation.Repo,
      {DNSCluster, query: Application.get_env(:inventory_reservation, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: InventoryReservation.PubSub},
      {Registry, keys: :unique, name: InventoryReservation.Registry},
      {DynamicSupervisor, name: InventoryReservation.DynamicSupervisor, strategy: :one_for_one},
      InventoryReservationWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: InventoryReservation.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    InventoryReservationWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
