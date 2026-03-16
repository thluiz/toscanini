defmodule ToscaniniWeb.Router do
  use ToscaniniWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api/orchestrator", ToscaniniWeb do
    pipe_through :api

    get  "/health",           HealthController, :index
    post "/jobs",             JobController, :create
    get  "/jobs/:id",         JobController, :show
    post "/batch",            BatchController, :create
    get  "/batch/:id",        BatchController, :show
    post "/publish/podcast",  PublishController, :create
    post "/queue/:name/scale", QueueController, :scale
    get  "/scheduler/configs/:queue",  SchedulerController, :show
    put  "/scheduler/configs/:queue",  SchedulerController, :update
    get  "/pipelines/find",           PipelineController, :find_by_url
    post "/pipelines/:id/prioritize", PipelineController, :prioritize
  end
end
