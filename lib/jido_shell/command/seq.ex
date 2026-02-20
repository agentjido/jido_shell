defmodule Jido.Shell.Command.Seq do
  @moduledoc """
  Prints a sequence of numbers with delays. For testing streaming.

  ## Usage

      seq [count] [delay_ms]
  """

  @behaviour Jido.Shell.Command
  alias Jido.Shell.Error

  @impl true
  def name, do: "seq"

  @impl true
  def summary, do: "Print sequence of numbers"

  @impl true
  def schema do
    Zoi.map(%{
      args: Zoi.array(Zoi.string()) |> Zoi.max(2) |> Zoi.default([])
    })
  end

  @impl true
  def run(_state, args, emit) do
    case parse_count_and_delay(args.args) do
      {:ok, {count, delay}} ->
        if count > 0 do
          Enum.each(1..count, fn i ->
            emit.({:output, "#{i}\n"})
            if delay > 0, do: Process.sleep(delay)
          end)
        end

        {:ok, count}

      {:error, message} ->
        {:error, Error.validation("seq", [%{message: message}])}
    end
  end

  defp parse_count_and_delay([]), do: {:ok, {10, 100}}

  defp parse_count_and_delay([count_arg]) do
    with {:ok, count} <- parse_non_negative_integer(count_arg, 100_000, "count") do
      {:ok, {count, 100}}
    end
  end

  defp parse_count_and_delay([count_arg, delay_arg]) do
    with {:ok, count} <- parse_non_negative_integer(count_arg, 100_000, "count"),
         {:ok, delay} <- parse_non_negative_integer(delay_arg, 60_000, "delay_ms") do
      {:ok, {count, delay}}
    end
  end

  defp parse_non_negative_integer(raw, max_value, name) do
    case Integer.parse(raw) do
      {parsed, ""} when parsed >= 0 and parsed <= max_value ->
        {:ok, parsed}

      _ ->
        {:error, "seq #{name} must be an integer between 0 and #{max_value}"}
    end
  end
end
