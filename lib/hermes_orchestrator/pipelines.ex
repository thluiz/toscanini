defmodule HermesOrchestrator.Pipelines do
  @collectors %{
    "pocketcasts" => HermesOrchestrator.Collectors.Pocketcasts
  }

  def collector(name), do: Map.get(@collectors, name)
end
