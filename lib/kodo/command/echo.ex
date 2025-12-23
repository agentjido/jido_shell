defmodule Kodo.Command.Echo do
  @moduledoc """
  Prints arguments to output.

  ## Usage

      echo [args...]

  ## Examples

      echo hello world
      # Output: hello world
  """

  @behaviour Kodo.Command

  @impl true
  def name, do: "echo"

  @impl true
  def summary, do: "Print arguments to output"

  @impl true
  def schema do
    Zoi.map(%{
      args: Zoi.array(Zoi.string()) |> Zoi.default([])
    })
  end

  @impl true
  def run(_state, args, emit) do
    output = Enum.join(args.args, " ") <> "\n"
    emit.({:output, output})
    {:ok, nil}
  end
end
