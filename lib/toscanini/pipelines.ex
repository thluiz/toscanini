defmodule Toscanini.Pipelines do
  @collectors %{
    "pocketcasts" => Toscanini.Collectors.Pocketcasts,
    "youtube"     => Toscanini.Collectors.Youtube
  }

  def collector(name), do: Map.get(@collectors, name)
end
