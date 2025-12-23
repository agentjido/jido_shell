defmodule Kodo.Command.Sleep do
  @moduledoc """
  Sleeps for a duration. Useful for testing cancellation.

  ## Usage

      sleep [seconds]
  """

  @behaviour Kodo.Command

  @impl true
  def name, do: "sleep"

  @impl true
  def summary, do: "Sleep for a duration"

  @impl true
  def schema do
    Zoi.map(%{
      args: Zoi.array(Zoi.string()) |> Zoi.default([])
    })
  end

  @impl true
  def run(_state, args, emit) do
    seconds =
      case args.args do
        [] -> 1
        [s | _] -> String.to_integer(s)
      end

    emit.({:output, "Sleeping for #{seconds} seconds...\n"})

    Enum.each(1..seconds, fn i ->
      Process.sleep(1000)
      emit.({:output, "#{i}...\n"})
    end)

    emit.({:output, "Done!\n"})
    {:ok, nil}
  end
end
