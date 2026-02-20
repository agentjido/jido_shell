defmodule Jido.Shell.Command.Sleep do
  @moduledoc """
  Sleeps for a duration. Useful for testing cancellation.

  ## Usage

      sleep [seconds]
  """

  @behaviour Jido.Shell.Command
  alias Jido.Shell.Error

  @impl true
  def name, do: "sleep"

  @impl true
  def summary, do: "Sleep for a duration"

  @impl true
  def schema do
    Zoi.map(%{
      args: Zoi.array(Zoi.string()) |> Zoi.max(1) |> Zoi.default([])
    })
  end

  @impl true
  def run(_state, args, emit) do
    case parse_seconds(args.args) do
      {:ok, seconds} ->
        emit.({:output, "Sleeping for #{seconds} seconds...\n"})

        if seconds > 0 do
          Enum.each(1..seconds, fn i ->
            Process.sleep(1000)
            emit.({:output, "#{i}...\n"})
          end)
        end

        emit.({:output, "Done!\n"})
        {:ok, nil}

      {:error, message} ->
        {:error, Error.validation("sleep", [%{message: message}])}
    end
  end

  defp parse_seconds([]), do: {:ok, 1}

  defp parse_seconds([seconds_arg]) do
    case Integer.parse(seconds_arg) do
      {seconds, ""} when seconds >= 0 and seconds <= 3_600 ->
        {:ok, seconds}

      _ ->
        {:error, "sleep seconds must be an integer between 0 and 3600"}
    end
  end
end
