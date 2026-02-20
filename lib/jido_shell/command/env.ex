defmodule Jido.Shell.Command.Env do
  @moduledoc """
  Display or set environment variables.

  ## Usage

      env               # List all variables
      env VAR           # Show specific variable
      env VAR=value     # Set variable
  """

  @behaviour Jido.Shell.Command

  @impl true
  def name, do: "env"

  @impl true
  def summary, do: "Display or set environment variables"

  @impl true
  def schema do
    Zoi.map(%{
      args: Zoi.array(Zoi.string()) |> Zoi.default([])
    })
  end

  @impl true
  def run(state, args, emit) do
    case args.args do
      [] ->
        output =
          state.env
          |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)
          |> Enum.sort()
          |> Enum.join("\n")

        if output == "" do
          emit.({:output, "(no environment variables)\n"})
        else
          emit.({:output, output <> "\n"})
        end

        {:ok, state.env}

      [arg] ->
        if String.contains?(arg, "=") do
          [name | rest] = String.split(arg, "=", parts: 2)
          value = Enum.join(rest, "=")
          new_env = Map.put(state.env, name, value)
          {:ok, {:state_update, %{env: new_env}}}
        else
          case Map.get(state.env, arg) do
            nil ->
              emit.({:output, "(not set)\n"})
              {:ok, nil}

            value ->
              emit.({:output, "#{arg}=#{value}\n"})
              {:ok, value}
          end
        end

      _ ->
        {:error, Jido.Shell.Error.validation("env", [%{message: "usage: env [VAR] or env VAR=value"}])}
    end
  end
end
