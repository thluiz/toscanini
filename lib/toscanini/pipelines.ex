defmodule Toscanini.Pipelines do
  @collectors %{
    "pocketcasts" => Toscanini.Collectors.Pocketcasts
  }

  def collector(name), do: Map.get(@collectors, name)
end
