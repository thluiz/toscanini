defmodule ToscaniniWeb.Router do
  use ToscaniniWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api/orchestrator", ToscaniniWeb do
    pipe_through :api

    get  "/health",   HealthController, :index
    post "/jobs",     JobController, :create
    get  "/jobs/:id", JobController, :show
  end
end
