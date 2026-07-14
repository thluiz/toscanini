defmodule Toscanini.Feeds do
  @moduledoc """
  Assinaturas de feed: cadastro de podcasts e deteção periódica de episódios
  novos. Produtor a montante do pipeline — não toca no núcleo (Pipeline/Batch).

  Regras de desenho:

    * **Backfill off**: `subscribe/1` grava um watermark (`last_published_at`) e
      NÃO processa o catálogo. Só episódios publicados depois entram.
    * **Janela quente**: `due?/2` checa de `hot_interval_min` em `hot_interval_min`
      nos dias de `check_days`; fora deles, só a cada `idle_interval_min` (rede de
      segurança diária).
    * **Conditional GET**: `check/1` reusa etag/last_modified pra baratear o poll.
  """
  import Ecto.Query
  require Logger

  alias Toscanini.{Repo, FeedSubscription, Batches}
  alias Toscanini.Collectors.Pocketcasts

  @day_abbr {"mon", "tue", "wed", "thu", "fri", "sat", "sun"}

  # Gap mínimo desde o último check para a rede de segurança disparar (evita
  # duplo disparo na hora-âncora e respeita checks recentes de dia quente).
  @safety_min_gap_hours 12

  # ---- CRUD -----------------------------------------------------------------

  def list_subscriptions do
    Repo.all(from s in FeedSubscription, order_by: [desc: s.inserted_at])
  end

  def list_active do
    Repo.all(from s in FeedSubscription, where: s.active == true)
  end

  def get_subscription(id), do: Repo.get(FeedSubscription, id)
  def get_subscription!(id), do: Repo.get!(FeedSubscription, id)

  # Update vindo do HTTP (input não-confiável): aplica a allowlist de campos que
  # o utilizador pode alterar. Campos internos (watermark, etag) NÃO passam aqui.
  def update_subscription(%FeedSubscription{} = sub, attrs) do
    do_update(sub, normalize_attrs(attrs))
  end

  # Update interno (confiável): grava watermark/etag/last_checked_at diretamente,
  # sem a allowlist. O changeset ainda é o guarda (só casta @castable).
  defp do_update(%FeedSubscription{} = sub, attrs) do
    sub
    |> FeedSubscription.changeset(encode_check_days(attrs))
    |> Repo.update()
  end

  def delete_subscription(%FeedSubscription{} = sub), do: Repo.delete(sub)

  # ---- Subscribe (watermark init, sem submeter) -----------------------------

  @doc """
  Cria uma assinatura. Aceita `feed_ref` (podcast_uuid) ou `url` (de podcast/
  episódio PocketCasts, da qual extrai o uuid). Faz um fetch inicial só pra
  gravar o watermark e os headers de cache — **não submete nenhum episódio**.
  """
  def subscribe(attrs) do
    attrs = normalize_attrs(attrs)

    with {:ok, feed_ref} <- resolve_feed_ref(attrs) do
      attrs = Map.put(attrs, :feed_ref, feed_ref)

      %FeedSubscription{id: Ecto.UUID.generate()}
      |> FeedSubscription.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, sub}      -> {:ok, prime_watermark(sub)}
        {:error, _} = e -> e
      end
    end
  end

  # Grava o watermark inicial = data do episódio mais recente atual (ou "agora"
  # se o feed falhar/vier vazio), garantindo que só o PRÓXIMO episódio entra.
  defp prime_watermark(%FeedSubscription{source: "pocketcasts"} = sub) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    updates =
      case Pocketcasts.fetch_podcast_episodes(sub.feed_ref) do
        {:ok, %{episodes: episodes} = feed} ->
          {latest_dt, latest_uuid} = latest_episode(episodes)

          %{
            last_published_at: latest_dt || now,
            last_episode_uuid: latest_uuid,
            etag:              feed[:etag],
            last_modified:     feed[:last_modified],
            last_checked_at:   now,
            title:             sub.title || get_in(feed, [:podcast_info, :title])
          }

        other ->
          Logger.warning("[Feeds] fetch inicial falhou p/ #{sub.feed_ref}: #{inspect(other)}")
          %{last_published_at: now, last_checked_at: now}
      end

    {:ok, primed} = do_update(sub, updates)
    primed
  end

  defp prime_watermark(sub), do: sub

  # ---- Cadência -------------------------------------------------------------

  @doc """
  Decide se a assinatura deve ser checada agora. Dentro da janela quente
  (dia ∈ check_days, ou check_days vazio) usa `hot_interval_min` (poll horário).
  Fora dela, roda uma **rede de segurança 1×/dia à hora UTC configurada**
  (`FeedsConfig.safety_hour_utc/0`, default 06:00 UTC — editável em runtime, sem
  redeploy) — âncora de relógio, não intervalo à deriva.
  """
  def due?(%FeedSubscription{} = sub, now \\ DateTime.utc_now()) do
    if hot?(sub, now) do
      case sub.last_checked_at do
        nil  -> true
        last -> DateTime.diff(now, last, :minute) >= sub.hot_interval_min
      end
    else
      safety_due?(sub, now)
    end
  end

  # Rede de segurança: só dispara quando a hora UTC == safety_hour_utc e faz pelo
  # menos ~meio dia desde o último check (evita disparo duplo e o caso de já ter
  # sido checado num dia quente recente).
  defp safety_due?(sub, now) do
    cond do
      now.hour != Toscanini.FeedsConfig.safety_hour_utc() -> false
      is_nil(sub.last_checked_at)                         -> true
      true -> DateTime.diff(now, sub.last_checked_at, :hour) >= @safety_min_gap_hours
    end
  end

  defp hot?(%FeedSubscription{} = sub, now) do
    case FeedSubscription.check_days(sub) do
      [] -> true
      days -> today_abbr(now) in Enum.map(days, &String.slice(&1, 0, 3))
    end
  end

  defp today_abbr(now) do
    idx = now |> DateTime.to_date() |> Date.day_of_week()
    elem(@day_abbr, idx - 1)
  end

  # ---- Check (delta por watermark → batch) ----------------------------------

  @doc """
  Checa uma assinatura por episódios novos. Em `304`/sem novidade não submete
  nada; havendo episódios com `published > watermark`, dispara um batch com eles
  e avança o watermark. Devolve `{:ok, :no_change}` | `{:ok, {:submitted, n}}` |
  `{:error, reason}`.
  """
  def check(%FeedSubscription{source: "pocketcasts"} = sub) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    opts = [etag: sub.etag, last_modified: sub.last_modified]

    case Pocketcasts.fetch_podcast_episodes(sub.feed_ref, opts) do
      {:not_modified, _} ->
        touch_checked(sub, now)
        {:ok, :no_change}

      {:ok, %{episodes: episodes} = feed} ->
        new = new_episodes(episodes, sub.last_published_at)

        base = %{
          etag:            feed[:etag],
          last_modified:   feed[:last_modified],
          last_checked_at: now
        }

        if new == [] do
          {:ok, _} = do_update(sub, base)
          {:ok, :no_change}
        else
          urls = Enum.map(new, fn {ep, _dt} -> Pocketcasts.episode_url(sub.feed_ref, ep["uuid"]) end)
          {:ok, batch, _pid} = Batches.start_batch(urls, "pocketcasts", %{})

          {latest_dt, latest_uuid} = latest_episode(Enum.map(new, fn {ep, _} -> ep end))

          {:ok, _} =
            do_update(
              sub,
              Map.merge(base, %{last_published_at: latest_dt, last_episode_uuid: latest_uuid})
            )

          Logger.info("[Feeds] #{sub.feed_ref}: #{length(new)} episódio(s) novo(s) → batch #{batch.id}")
          {:ok, {:submitted, length(new)}}
        end

      {:error, reason} ->
        Logger.warning("[Feeds] check falhou p/ #{sub.feed_ref}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def check(%FeedSubscription{source: source}), do: {:error, {:unsupported_source, source}}

  defp touch_checked(sub, now) do
    {:ok, _} = do_update(sub, %{last_checked_at: now})
    :ok
  end

  # Episódios com published estritamente > watermark, ordenados asc. Se o
  # watermark for nil (não deveria após subscribe), nada entra — backfill off.
  @doc false
  def new_episodes(_episodes, nil), do: []

  def new_episodes(episodes, watermark) do
    episodes
    |> Enum.map(fn ep -> {ep, parse_published(ep["published"])} end)
    |> Enum.filter(fn {_ep, dt} -> dt != nil and DateTime.compare(dt, watermark) == :gt end)
    |> Enum.sort_by(fn {_ep, dt} -> DateTime.to_unix(dt) end)
  end

  # Devolve {max_published_dt | nil, uuid_do_mais_recente | nil}
  @doc false
  def latest_episode([]), do: {nil, nil}

  def latest_episode(episodes) do
    episodes
    |> Enum.map(fn ep -> {ep, parse_published(ep["published"])} end)
    |> Enum.filter(fn {_ep, dt} -> dt != nil end)
    |> Enum.max_by(fn {_ep, dt} -> DateTime.to_unix(dt) end, fn -> nil end)
    |> case do
      nil -> {nil, nil}
      {ep, dt} -> {dt, ep["uuid"]}
    end
  end

  defp parse_published(nil), do: nil

  defp parse_published(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> DateTime.truncate(dt, :second)
      _ -> nil
    end
  end

  defp parse_published(_), do: nil

  # ---- Helpers ---------------------------------------------------------------

  defp resolve_feed_ref(%{feed_ref: ref}) when is_binary(ref) and ref != "", do: {:ok, ref}

  defp resolve_feed_ref(%{url: url}) when is_binary(url) and url != "" do
    # Segue redirects (short links pca.st/CODE → pocketcasts.com/podcast/slug/uuid).
    Pocketcasts.resolve_podcast_uuid(url)
  end

  defp resolve_feed_ref(_), do: {:error, :missing_feed_ref}

  @allowed_keys ~w(source feed_ref url title active check_days
                   hot_interval_min idle_interval_min)a

  # Aceita chaves string (HTTP/JSON) ou atom; ignora chaves desconhecidas;
  # serializa check_days lista→JSON.
  defp normalize_attrs(attrs) do
    attrs
    |> Enum.reduce(%{}, fn {k, v}, acc ->
      case safe_atom(k) do
        key when key in @allowed_keys -> Map.put(acc, key, v)
        _ -> acc
      end
    end)
    |> encode_check_days()
  end

  defp encode_check_days(%{check_days: days} = attrs) when is_list(days) do
    %{attrs | check_days: Jason.encode!(Enum.map(days, &String.downcase(to_string(&1))))}
  end

  defp encode_check_days(attrs), do: attrs

  defp safe_atom(k) when is_atom(k), do: k

  defp safe_atom(k) when is_binary(k) do
    String.to_existing_atom(k)
  rescue
    ArgumentError -> nil
  end
end
