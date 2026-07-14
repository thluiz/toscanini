defmodule ToscaniniWeb.FeedController do
  use ToscaniniWeb, :controller

  alias Toscanini.{Feeds, FeedSubscription, FeedsConfig}
  alias Toscanini.Workers.FeedCheckWorker

  # GET /feeds/config — config runtime dos feeds (ex.: hora-âncora da rede diária)
  def get_config(conn, _params) do
    json(conn, FeedsConfig.read())
  end

  # PUT /feeds/config — {safety_hour_utc: 0..23}. Muda ao vivo, sem restart.
  def put_config(conn, params) do
    case FeedsConfig.put(Map.drop(params, ["id"])) do
      {:ok, cfg}       -> json(conn, cfg)
      {:error, reason} -> conn |> put_status(422) |> json(%{error: reason})
    end
  end

  # POST /subscriptions  — {source?, feed_ref | url, title?, check_days?, ...}
  def create(conn, params) do
    case Feeds.subscribe(params) do
      {:ok, sub} ->
        conn |> put_status(201) |> json(render_sub(sub))

      {:error, %Ecto.Changeset{} = cs} ->
        conn |> put_status(422) |> json(%{error: "invalid subscription", details: errors(cs)})

      {:error, reason} ->
        conn |> put_status(400) |> json(%{error: to_string_reason(reason)})
    end
  end

  # GET /subscriptions
  def index(conn, _params) do
    json(conn, %{subscriptions: Enum.map(Feeds.list_subscriptions(), &render_sub/1)})
  end

  # GET /subscriptions/:id
  def show(conn, %{"id" => id}) do
    with_sub(conn, id, fn sub -> json(conn, render_sub(sub)) end)
  end

  # PUT /subscriptions/:id  — intervalos, check_days, active, title
  def update(conn, %{"id" => id} = params) do
    with_sub(conn, id, fn sub ->
      case Feeds.update_subscription(sub, Map.drop(params, ["id"])) do
        {:ok, updated} ->
          json(conn, render_sub(updated))

        {:error, cs} ->
          conn |> put_status(422) |> json(%{error: "invalid update", details: errors(cs)})
      end
    end)
  end

  # DELETE /subscriptions/:id
  def delete(conn, %{"id" => id}) do
    with_sub(conn, id, fn sub ->
      {:ok, _} = Feeds.delete_subscription(sub)
      json(conn, %{deleted: id})
    end)
  end

  # POST /subscriptions/:id/check  — força uma checagem agora
  def check_now(conn, %{"id" => id}) do
    with_sub(conn, id, fn sub ->
      %{"subscription_id" => sub.id} |> FeedCheckWorker.new() |> Oban.insert!()
      conn |> put_status(202) |> json(%{queued: true, subscription_id: sub.id})
    end)
  end

  # ---- helpers --------------------------------------------------------------

  defp with_sub(conn, id, fun) do
    case Feeds.get_subscription(id) do
      nil -> conn |> put_status(404) |> json(%{error: "subscription not found"})
      sub -> fun.(sub)
    end
  end

  defp render_sub(%FeedSubscription{} = s) do
    %{
      id:                s.id,
      source:            s.source,
      feed_ref:          s.feed_ref,
      title:             s.title,
      active:            s.active,
      auto_annotate:     s.auto_annotate,
      check_days:        FeedSubscription.check_days(s),
      hot_interval_min:  s.hot_interval_min,
      idle_interval_min: s.idle_interval_min,
      last_published_at: s.last_published_at,
      last_episode_uuid: s.last_episode_uuid,
      last_checked_at:   s.last_checked_at
    }
  end

  defp errors(cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
  end

  defp to_string_reason(:missing_feed_ref), do: "feed_ref or url is required"
  defp to_string_reason({:unsupported_source, s}), do: "unsupported source: #{s}"
  defp to_string_reason(reason), do: inspect(reason)
end
