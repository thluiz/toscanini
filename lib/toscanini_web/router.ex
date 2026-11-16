defmodule ToscaniniWeb.Router do
  use ToscaniniWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api/orchestrator", ToscaniniWeb do
    pipe_through :api

    get  "/health",           HealthController, :index
    get  "/status",           StatusController, :index
    post "/jobs",             JobController, :create
    get  "/jobs/:id",         JobController, :show
    post "/batch",            BatchController, :create
    get  "/batch/:id",        BatchController, :show
    post "/publish/podcast",  PublishController, :create
    post "/annotate",        AnnotateController, :create
    post "/publish/scholion", ScholionPublishController, :create
    post "/publish/webclip",  WebclipPublishController, :create
    get  "/parked",             ParkedController, :index
    post "/parked/:id/resume",  ParkedController, :resume
    post "/parked/:id/dismiss", ParkedController, :dismiss
    post "/ingest/local",   IngestLocalController, :create
    post "/queue/:name/scale", QueueController, :scale
    get  "/scheduler/configs/:queue",  SchedulerController, :show
    put  "/scheduler/configs/:queue",  SchedulerController, :update
    get  "/model-routing",              ModelRoutingController, :show
    get  "/model-routing/resolved",     ModelRoutingController, :resolved
    put  "/model-routing/profile",      ModelRoutingController, :set_profile
    put  "/model-routing/cases/*key",   ModelRoutingController, :set_case
    get  "/pipelines/find",           PipelineController, :find_by_url
    post "/pipelines/:id/prioritize", PipelineController, :prioritize

    get    "/feeds/config",            FeedController, :get_config
    put    "/feeds/config",            FeedController, :put_config
    post   "/subscriptions",           FeedController, :create
    get    "/subscriptions",           FeedController, :index
    get    "/subscriptions/:id",       FeedController, :show
    put    "/subscriptions/:id",       FeedController, :update
    delete "/subscriptions/:id",       FeedController, :delete
    post   "/subscriptions/:id/check", FeedController, :check_now
  end
end
