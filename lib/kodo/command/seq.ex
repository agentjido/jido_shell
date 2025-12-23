defmodule Kodo.Command.Seq do
  @moduledoc """
  Prints a sequence of numbers with delays. For testing streaming.

  ## Usage

      seq [count] [delay_ms]
  """

  @behaviour Kodo.Command

  @impl true
  def name, do: "seq"

  @impl true
  def summary, do: "Print sequence of numbers"

  @impl true
  def schema do
    Zoi.map(%{
      args: Zoi.array(Zoi.string()) |> Zoi.default([])
    })
  end

  @impl true
  def run(_state, args, emit) do
    {count, delay} =
      case args.args do
        [] -> {10, 100}
        [c] -> {String.to_integer(c), 100}
        [c, d | _] -> {String.to_integer(c), String.to_integer(d)}
      end

    Enum.each(1..count, fn i ->
      emit.({:output, "#{i}\n"})
      if delay > 0, do: Process.sleep(delay)
    end)

    {:ok, count}
  end
end
