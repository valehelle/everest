# Inventory Reservation System

## Project Overview

Elixir/OTP system that prevents overselling in high-concurrency flash sale scenarios. Uses the Actor Model (GenServer) as the concurrency control mechanism — no manual locks or mutexes. Phoenix LiveView provides the web UI, and PostgreSQL (via Ecto) provides persistence.

## Architecture

```
Application Supervisor
├── Registry (unique name per product, ETS atomic insert)
├── DynamicSupervisor
│   └── ProductServer (one GenServer per product, started on demand)
├── Ecto.Repo (PostgreSQL persistence)
├── Phoenix.Endpoint (HTTP + WebSocket)
```

- **ProductServer** — GenServer that holds inventory state and processes reserve/confirm/cancel/expire messages sequentially via its mailbox. Syncs state to DB.
- **Registry** — maps product IDs to PIDs, guarantees one GenServer per product
- **DynamicSupervisor** — starts ProductServer processes on demand
- **Ecto.Repo** — PostgreSQL database for persistent storage of products and reservations
- **Phoenix.Endpoint** — serves the LiveView UI on port 4000

## Key Design Decisions

- GenServer mailbox serializes all concurrent access — no race conditions by design
- `Process.send_after/3` handles reservation expiry (2-minute TTL)
- Expiry messages land in the same mailbox as reserve/confirm/cancel — no timing conflicts
- Available stock formula: `total_stock - confirmed_sales - active_reservations`
- DB provides persistence; GenServer provides concurrency control and in-memory speed
- Phoenix LiveView for real-time UI updates without writing API endpoints

## Commands

```bash
mix setup            # Install deps, create DB, run migrations
mix phx.server       # Start the server on http://localhost:4000
iex -S mix phx.server # Start with interactive shell
mix test             # Run all tests
mix test --trace     # Run with verbose output
mix ecto.reset       # Drop, create, and migrate DB
```

## File Structure

- `lib/inventory_reservation.ex` — Public API
- `lib/inventory_reservation/application.ex` — Supervision tree
- `lib/inventory_reservation/product_server.ex` — Core GenServer (business logic + locking strategy docs)
- `lib/inventory_reservation/repo.ex` — Ecto Repo
- `lib/inventory_reservation/schema/` — Ecto schemas (Product, Reservation)
- `lib/inventory_reservation_web/` — Phoenix web layer (endpoint, router, live views)
- `priv/repo/migrations/` — Database migrations
- `test/inventory_reservation_test.exs` — Tests for all 3 levels

## Testing Notes

- Expiry tests simulate timeout by sending `{:expire, reservation_id}` directly to the GenServer instead of waiting 2 minutes
- Concurrency tests use `Task.async` to spawn 500 real BEAM processes
- Each test uses a unique product ID to avoid cross-test interference
- Tests use Ecto SQL Sandbox for isolated database transactions
